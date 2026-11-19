import Darwin
import Foundation

enum AgentConfigWriteOutcome: Equatable {
    case applied
    case conflict
    case unavailable
    case partial
    case unknown
}

enum AgentConfigFileWriter {
    enum Stage { case beforeMutation, afterWrite, beforeSync, beforeVerification }

    static func write(rootPath: String, relativePath: String, expected: Data?, proposed: Data,
                      onStage: ((Stage) -> Bool)? = nil) -> AgentConfigWriteOutcome {
        let descriptor = open(rootPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return .unavailable }
        defer { close(descriptor) }
        return write(rootDescriptor: descriptor, relativePath: relativePath, expected: expected, proposed: proposed, onStage: onStage)
    }

    static func write(rootDescriptor: Int32, relativePath: String, expected: Data?, proposed: Data,
                      onStage: ((Stage) -> Bool)? = nil) -> AgentConfigWriteOutcome {
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !relativePath.hasPrefix("/"), !relativePath.utf8.contains(0),
              !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              proposed.count <= 262_144, expected == nil || expected!.count <= 262_144
        else { return .unavailable }
        var parent = dup(rootDescriptor)
        guard parent >= 0 else { return .unavailable }
        defer { close(parent) }
        for part in parts.dropLast() {
            let next = openat(parent, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { return .unavailable }
            close(parent)
            parent = next
        }
        let name = String(parts.last!)
        let flags = O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | (expected == nil ? O_CREAT | O_EXCL : 0)
        let descriptor = openat(parent, name, flags, mode_t(0o600))
        guard descriptor >= 0 else { return errno == EEXIST || errno == ENOENT || errno == ELOOP ? .conflict : .unavailable }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1,
              before.st_size >= 0, before.st_size <= 262_144 else { return .conflict }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return .unavailable }
        defer { flock(descriptor, LOCK_UN) }
        if let expected {
            var current = Data(count: Int(before.st_size))
            let count = current.withUnsafeMutableBytes { buffer in
                pread(descriptor, buffer.baseAddress, buffer.count, 0)
            }
            guard count == current.count, current == expected else { return .conflict }
        }
        guard onStage?(.beforeMutation) != false else { return expected == nil ? .partial : .unavailable }
        var currentInfo = stat()
        guard fstat(descriptor, &currentInfo) == 0,
              currentInfo.st_size == before.st_size, currentInfo.st_nlink == 1,
              currentInfo.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
              currentInfo.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
              currentInfo.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec,
              currentInfo.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec else { return .conflict }
        var named = stat()
        guard fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              named.st_dev == before.st_dev, named.st_ino == before.st_ino else { return .conflict }
        var offset = 0
        while offset < proposed.count {
            let count = proposed.withUnsafeBytes { buffer in
                pwrite(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, off_t(offset))
            }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return offset == 0 && expected != nil ? .unavailable : .partial }
            offset += count
            guard onStage?(.afterWrite) != false else { return .partial }
        }
        guard ftruncate(descriptor, off_t(proposed.count)) == 0 else { return .partial }
        guard onStage?(.beforeSync) != false else { return .unknown }
        guard fsync(descriptor) == 0, fsync(parent) == 0 else { return .unknown }
        guard onStage?(.beforeVerification) != false else { return .unknown }
        var after = stat()
        guard fstatat(parent, name, &after, AT_SYMLINK_NOFOLLOW) == 0,
              after.st_dev == before.st_dev, after.st_ino == before.st_ino,
              after.st_nlink == 1, after.st_size == proposed.count else { return .unknown }
        var verified = Data(count: proposed.count)
        let readCount = verified.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, $0.count, 0) }
        guard readCount == proposed.count, verified == proposed else { return .unknown }
        return .applied
    }
}

final class AgentConfigWriteRoot {
    private let descriptor: Int32
    let identity: AnalyzerSafeRoot.RootIdentity
    let canonicalPath: String
    let sessionID = UUID().uuidString.lowercased()

    init(rootPath: String, expectedIdentity: AnalyzerSafeRoot.RootIdentity) throws {
        let descriptor = open(rootPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw AgentExportPlanError.stale }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_dev == expectedIdentity.device, info.st_ino == expectedIdentity.inode else {
            close(descriptor)
            throw AgentExportPlanError.stale
        }
        self.descriptor = descriptor
        self.identity = expectedIdentity
        self.canonicalPath = URL(fileURLWithPath: rootPath).resolvingSymlinksInPath().standardizedFileURL.path
    }

    deinit { close(descriptor) }

    func write(document: AgentExportDocument) -> AgentConfigWriteOutcome {
        guard document.rootIdentity == identity, document.rootSessionID == sessionID else { return .conflict }
        var namedRoot = stat()
        guard lstat(canonicalPath, &namedRoot) == 0, namedRoot.st_mode & S_IFMT == S_IFDIR,
              namedRoot.st_dev == identity.device, namedRoot.st_ino == identity.inode else { return .conflict }
        let prefix = canonicalPath == "/" ? "/" : canonicalPath + "/"
        let targetBytes = Array(document.plan.binding.targetPath.utf8)
        let prefixBytes = Array(prefix.utf8)
        guard targetBytes.starts(with: prefixBytes) else { return .conflict }
        let relative = String(decoding: targetBytes.dropFirst(prefixBytes.count), as: UTF8.self)
        return write(relativePath: relative, expected: document.previousContent, proposed: document.proposedContent)
    }

    func write(relativePath: String, expected: Data?, proposed: Data) -> AgentConfigWriteOutcome {
        AgentConfigFileWriter.write(rootDescriptor: descriptor, relativePath: relativePath,
            expected: expected, proposed: proposed)
    }
}
