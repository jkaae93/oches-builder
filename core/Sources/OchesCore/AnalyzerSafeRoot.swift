import Darwin
import Foundation

/// Descriptor-relative primitive only. Callers must verify workspace identity,
/// scope approval and exclusions before invoking it; this is not an analyzer API.
final class AnalyzerSafeRoot {
    enum AccessError: Error, Equatable {
        case invalidPath
        case unavailable
        case notRegularFile
        case limitExceeded
        case changedDuringRead
        case excluded
    }

    private let rootFD: Int32

    init(rootPath: String) throws {
        let descriptor = open(rootPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw AccessError.unavailable }
        rootFD = descriptor
    }

    deinit { close(rootFD) }

    /// Reads a regular file without following links, including in parent components.
    /// The caller owns the returned bytes and must not log or transmit them.
    func read(relativePath: String, maximumBytes: Int, userExcludedPaths: Set<String> = [], beforeFinalOpen: (() -> Void)? = nil, beforeFinalStat: (() -> Void)? = nil) throws -> Data {
        guard maximumBytes > 0, maximumBytes <= 1_048_576,
              !relativePath.hasPrefix("/"), !relativePath.utf8.contains(0) else { throw AccessError.invalidPath }
        guard try AnalyzerExclusions.classify(relativePath: relativePath, userExcludedPaths: userExcludedPaths) == nil else { throw AccessError.excluded }
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw AccessError.invalidPath }
        var current = dup(rootFD)
        guard current >= 0 else { throw AccessError.unavailable }
        defer { close(current) }
        for (index, part) in parts.enumerated() {
            let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | (index == parts.count - 1 ? O_NONBLOCK : O_DIRECTORY)
            if index == parts.count - 1 { beforeFinalOpen?() }
            let next = openat(current, String(part), flags)
            guard next >= 0 else { throw AccessError.unavailable }
            close(current)
            current = next
        }
        var before = stat()
        guard fstat(current, &before) == 0 else { throw AccessError.unavailable }
        guard (before.st_mode & S_IFMT) == S_IFREG else { throw AccessError.notRegularFile }
        guard before.st_size >= 0, before.st_size <= maximumBytes else { throw AccessError.limitExceeded }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(current, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw AccessError.unavailable
            }
            if count == 0 { break }
            guard result.count + count <= maximumBytes else { throw AccessError.limitExceeded }
            result.append(contentsOf: buffer.prefix(count))
        }
        beforeFinalStat?()
        var after = stat()
        guard fstat(current, &after) == 0 else { throw AccessError.unavailable }
        guard before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              Int64(result.count) == after.st_size else { throw AccessError.changedDuringRead }
        return result
    }
}

extension AnalyzerSafeRoot {
    struct PreviewEntry {
        enum Kind { case regular, directory, symbolicLink, other }
        let relativePath: String
        let kind: Kind
        let size: Int64
        let exclusion: AnalyzerExclusion?
        /// Link text only; never dereferenced. Nil if unreadable or not a link.
        let symbolicLinkTarget: String?
    }

    struct Preview {
        let entries: [PreviewEntry]
        /// A partial result never asserts a complete inventory.
        let partialReasons: Set<String>
    }

    /// Internal metadata-only traversal. No content is read and no link followed.
    /// A caller still needs a verified workspace and policy before presenting it.
    func preview(userExcludedPaths: Set<String> = [], maximumEntries: Int = 10_000, maximumSeconds: TimeInterval = 300) throws -> Preview {
        guard maximumEntries > 0, maximumEntries <= 10_000, maximumSeconds > 0, maximumSeconds <= 300 else { throw AccessError.invalidPath }
        // Validate every user rule even for an empty directory.
        _ = try AnalyzerExclusions.classify(relativePath: "validation", userExcludedPaths: userExcludedPaths)
        let deadline = ProcessInfo.processInfo.systemUptime + maximumSeconds
        var entries: [PreviewEntry] = []
        var reasons = Set<String>()

        func walk(_ directoryFD: Int32, prefix: String, depth: Int) {
            guard depth <= 64 else { reasons.insert("depth_limit"); return }
            guard reasons.isDisjoint(with: ["entry_limit", "time_limit"]) else { return }
            // dup shares the directory offset; openat creates an independent stream
            // so repeated previews do not accidentally start at end-of-directory.
            let streamFD = openat(directoryFD, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard streamFD >= 0, let stream = fdopendir(streamFD) else {
                if streamFD >= 0 { close(streamFD) }
                reasons.insert("directory_unavailable")
                return
            }
            defer { closedir(stream) }
            while true {
                if ProcessInfo.processInfo.systemUptime >= deadline { reasons.insert("time_limit"); return }
                errno = 0
                guard let entry = readdir(stream) else {
                    if errno != 0 { reasons.insert("directory_unavailable") }
                    return
                }
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(validatingUTF8: $0) }
                }
                guard let name else { reasons.insert("invalid_filename"); continue }
                if name == "." || name == ".." { continue }
                if entries.count >= maximumEntries { reasons.insert("entry_limit"); return }
                let relativePath = prefix.isEmpty ? name : prefix + "/" + name
                let exclusion: AnalyzerExclusion?
                do { exclusion = try AnalyzerExclusions.classify(relativePath: relativePath, userExcludedPaths: userExcludedPaths) }
                catch { reasons.insert("invalid_filename"); continue }
                var info = stat()
                guard fstatat(directoryFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                    reasons.insert("entry_unavailable")
                    continue
                }
                let type = info.st_mode & S_IFMT
                let kind: PreviewEntry.Kind = type == S_IFREG ? .regular : type == S_IFDIR ? .directory : type == S_IFLNK ? .symbolicLink : .other
                var linkTarget: String?
                if kind == .symbolicLink {
                    var buffer = [CChar](repeating: 0, count: 4096)
                    let length = readlinkat(directoryFD, name, &buffer, buffer.count)
                    if length >= 0 && length < buffer.count {
                        linkTarget = buffer.withUnsafeBufferPointer { pointer in
                            String(bytes: UnsafeRawBufferPointer(start: pointer.baseAddress, count: length), encoding: .utf8)
                        }
                        if linkTarget == nil { reasons.insert("link_target_unavailable") }
                        var linkAfter = stat()
                        if fstatat(directoryFD, name, &linkAfter, AT_SYMLINK_NOFOLLOW) != 0 ||
                            linkAfter.st_dev != info.st_dev || linkAfter.st_ino != info.st_ino ||
                            linkAfter.st_ctimespec.tv_sec != info.st_ctimespec.tv_sec || linkAfter.st_ctimespec.tv_nsec != info.st_ctimespec.tv_nsec {
                            linkTarget = nil
                            reasons.insert("path_changed")
                        }
                    } else { reasons.insert("link_target_unavailable") }
                }
                entries.append(PreviewEntry(relativePath: relativePath, kind: kind, size: info.st_size, exclusion: exclusion, symbolicLinkTarget: linkTarget))
                if kind == .directory && exclusion == nil {
                    let child = openat(directoryFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard child >= 0 else { reasons.insert("directory_unavailable"); continue }
                    // Ensure the object enumerated is the one opened, or report a race.
                    var opened = stat()
                    if fstat(child, &opened) == 0 && opened.st_dev == info.st_dev && opened.st_ino == info.st_ino {
                        walk(child, prefix: relativePath, depth: depth + 1)
                    } else { reasons.insert("path_changed") }
                    close(child)
                }
            }
        }
        walk(rootFD, prefix: "", depth: 0)
        return Preview(entries: entries, partialReasons: reasons)
    }
}
