import Darwin
import Foundation
import CryptoKit

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
        case multipleHardLinks
    }

    private let rootFD: Int32

    init(rootPath: String) throws {
        let descriptor = open(rootPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw AccessError.unavailable }
        rootFD = descriptor
    }

    deinit { close(rootFD) }

    struct RootIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    /// Identity of the directory already held open, not a caller-supplied path.
    func rootIdentity() throws -> RootIdentity {
        var info = stat()
        guard fstat(rootFD, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { throw AccessError.unavailable }
        return RootIdentity(device: info.st_dev, inode: info.st_ino)
    }

    struct ReadEvidence {
        let bytes: Data
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let sha256: String
    }

    /// Internal primitive. No bytes may be logged or sent to a provider.
    func read(relativePath: String, maximumBytes: Int, userExcludedPaths: [String] = [], beforeFinalOpen: (() -> Void)? = nil, beforeFinalStat: (() -> Void)? = nil) throws -> Data {
        try readEvidence(relativePath: relativePath, maximumBytes: maximumBytes, userExcludedPaths: userExcludedPaths, beforeFinalOpen: beforeFinalOpen, beforeFinalStat: beforeFinalStat).bytes
    }

    func readEvidence(relativePath: String, maximumBytes: Int, userExcludedPaths: [String] = [], exceptionPaths: [String] = [], expectedDevice: dev_t? = nil, expectedInode: ino_t? = nil, beforeFinalOpen: (() -> Void)? = nil, beforeFinalStat: (() -> Void)? = nil, onBytesRead: ((Int) -> Void)? = nil, shouldStop: () -> Bool = { false }) throws -> ReadEvidence {
        guard maximumBytes > 0, maximumBytes <= 1_048_576,
              !relativePath.hasPrefix("/"), !relativePath.utf8.contains(0) else { throw AccessError.invalidPath }
        try AnalyzerExclusions.validateExceptions(exceptionPaths)
        let exclusion = try AnalyzerExclusions.classify(relativePath: relativePath, userExcludedPaths: userExcludedPaths)
        guard exclusion == nil || (exclusion != .userRule && AnalyzerExclusions.isExactException(relativePath, in: exceptionPaths)) else { throw AccessError.excluded }
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
        // A hard link can alias a file outside the approved namespace.
        guard before.st_nlink == 1 else { throw AccessError.multipleHardLinks }
        guard (expectedDevice == nil || expectedDevice == before.st_dev), (expectedInode == nil || expectedInode == before.st_ino) else { throw AccessError.changedDuringRead }
        guard before.st_size >= 0, before.st_size <= maximumBytes else { throw AccessError.limitExceeded }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while result.count < maximumBytes {
            guard !shouldStop() else { throw AccessError.unavailable }
            let count = Darwin.read(current, &buffer, min(buffer.count, maximumBytes - result.count))
            if count < 0 {
                if errno == EINTR { continue }
                throw AccessError.unavailable
            }
            if count == 0 { break }
            onBytesRead?(count)
            result.append(contentsOf: buffer.prefix(count))
        }
        beforeFinalStat?()
        var after = stat()
        guard fstat(current, &after) == 0 else { throw AccessError.unavailable }
        guard before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec, after.st_nlink == 1,
              Int64(result.count) == after.st_size else { throw AccessError.changedDuringRead }
        return ReadEvidence(bytes: result, size: after.st_size, modifiedSeconds: Int64(after.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(after.st_mtimespec.tv_nsec), sha256: SHA256.hash(data: result).map { String(format: "%02x", $0) }.joined())
    }
}

extension AnalyzerSafeRoot {
    struct PreviewEntry {
        enum Kind { case regular, directory, symbolicLink, other }
        let relativePath: String
        let kind: Kind
        let size: Int64
        let device: dev_t
        let inode: ino_t
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
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
    func preview(userExcludedPaths: [String] = [], exceptionPaths: [String] = [], maximumEntries: Int = 10_000, maximumSeconds: TimeInterval = 300, isCancelled: () -> Bool = { false }) throws -> Preview {
        guard maximumEntries > 0, maximumEntries <= 10_000, maximumSeconds > 0, maximumSeconds <= 300 else { throw AccessError.invalidPath }
        // Validate every user rule even for an empty directory.
        _ = try AnalyzerExclusions.classify(relativePath: "validation", userExcludedPaths: userExcludedPaths)
        try AnalyzerExclusions.validateExceptions(exceptionPaths)
        let deadline = ProcessInfo.processInfo.systemUptime + maximumSeconds
        var entries: [PreviewEntry] = []
        var reasons = Set<String>()

        func walk(_ directoryFD: Int32, prefix: String, depth: Int, restricted: Bool) {
            guard depth <= 64 else { reasons.insert("depth_limit"); return }
            guard reasons.isDisjoint(with: ["entry_limit", "time_limit", "cancelled"]) else { return }
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
                if isCancelled() { reasons.insert("cancelled"); return }
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
                if restricted && !AnalyzerExclusions.isExactException(relativePath, in: exceptionPaths) && !AnalyzerExclusions.leadsToException(relativePath, in: exceptionPaths) { continue }
                var exclusion: AnalyzerExclusion?
                do { exclusion = try AnalyzerExclusions.classify(relativePath: relativePath, userExcludedPaths: userExcludedPaths) }
                catch { reasons.insert("invalid_filename"); continue }
                var info = stat()
                guard fstatat(directoryFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                    reasons.insert("entry_unavailable")
                    continue
                }
                let type = info.st_mode & S_IFMT
                let kind: PreviewEntry.Kind = type == S_IFREG ? .regular : type == S_IFDIR ? .directory : type == S_IFLNK ? .symbolicLink : .other
                if kind == .regular && exclusion != .userRule && AnalyzerExclusions.isExactException(relativePath, in: exceptionPaths) { exclusion = nil }
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
                entries.append(PreviewEntry(relativePath: relativePath, kind: kind, size: info.st_size, device: info.st_dev, inode: info.st_ino, modifiedSeconds: Int64(info.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec), exclusion: exclusion, symbolicLinkTarget: linkTarget))
                if kind == .directory && (exclusion == nil || (exclusion != .userRule && AnalyzerExclusions.leadsToException(relativePath, in: exceptionPaths))) {
                    let child = openat(directoryFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard child >= 0 else { reasons.insert("directory_unavailable"); continue }
                    // Ensure the object enumerated is the one opened, or report a race.
                    var opened = stat()
                    if fstat(child, &opened) == 0 && opened.st_dev == info.st_dev && opened.st_ino == info.st_ino {
                        walk(child, prefix: relativePath, depth: depth + 1, restricted: restricted || exclusion != nil)
                    } else { reasons.insert("path_changed") }
                    close(child)
                }
            }
        }
        walk(rootFD, prefix: "", depth: 0, restricted: false)
        return Preview(entries: entries, partialReasons: reasons)
    }
}

extension AnalyzerSafeRoot {
    struct FileEvidence {
        let relativePath: String
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let sha256: String
    }

    struct EvidenceCollection {
        let preview: Preview
        let files: [FileEvidence]
        /// Paths and categories only; no file contents or OS error text.
        let unreadReasons: [String: String]
        let partialReasons: Set<String>
        let cancelled: Bool
    }

    /// Internal local-only candidate; requires verified approval and storage
    /// integration before it can be used as a product analysis operation.
    func collectEvidence(userExcludedPaths: [String] = [], exceptionPaths: [String] = [], maximumEntries: Int = 10_000,
                         maximumTotalBytes: Int = 104_857_600, maximumFileBytes: Int = 1_048_576,
                         maximumSeconds: TimeInterval = 300, isCancelled: () -> Bool = { false }) throws -> EvidenceCollection {
        guard maximumTotalBytes > 0, maximumTotalBytes <= 104_857_600,
              maximumFileBytes > 0, maximumFileBytes <= 1_048_576,
              maximumSeconds > 0, maximumSeconds <= 300 else { throw AccessError.invalidPath }
        let deadline = ProcessInfo.processInfo.systemUptime + maximumSeconds
        let scope = try preview(userExcludedPaths: userExcludedPaths, exceptionPaths: exceptionPaths, maximumEntries: maximumEntries, maximumSeconds: maximumSeconds, isCancelled: isCancelled)
        var reasons = scope.partialReasons
        var unread: [String: String] = [:]
        var files: [FileEvidence] = []
        var total = 0
        var cancelled = scope.partialReasons.contains("cancelled")
        for entry in scope.entries where entry.kind == .regular && entry.exclusion == nil {
            if cancelled { break }
            if isCancelled() { cancelled = true; reasons.insert("cancelled"); break }
            if ProcessInfo.processInfo.systemUptime >= deadline { reasons.insert("time_limit"); break }
            if entry.size < 0 { unread[entry.relativePath] = "metadata_unavailable"; reasons.insert("read_incomplete"); continue }
            if entry.size > maximumFileBytes { unread[entry.relativePath] = "file_limit"; reasons.insert("file_limit"); continue }
            let remaining = maximumTotalBytes - total
            if entry.size > remaining || remaining == 0 { unread[entry.relativePath] = "total_limit"; reasons.insert("total_limit"); break }
            var stoppedForCancellation = false
            var stoppedForTime = false
            do {
                let result = try readEvidence(relativePath: entry.relativePath, maximumBytes: min(maximumFileBytes, remaining), userExcludedPaths: userExcludedPaths, exceptionPaths: exceptionPaths, expectedDevice: entry.device, expectedInode: entry.inode, onBytesRead: { total += $0 }, shouldStop: {
                    if isCancelled() { stoppedForCancellation = true; return true }
                    if ProcessInfo.processInfo.systemUptime >= deadline { stoppedForTime = true; return true }
                    return false
                })
                files.append(FileEvidence(relativePath: entry.relativePath, size: result.size, modifiedSeconds: result.modifiedSeconds, modifiedNanoseconds: result.modifiedNanoseconds, sha256: result.sha256))
            } catch {
                unread[entry.relativePath] = "read_unavailable_or_changed"
                reasons.insert("read_incomplete")
            }
            if stoppedForCancellation || isCancelled() { cancelled = true; reasons.insert("cancelled"); break }
            if stoppedForTime || ProcessInfo.processInfo.systemUptime >= deadline { reasons.insert("time_limit"); break }
        }
        // Cancellation after the final read still prevents a complete result.
        if isCancelled() { cancelled = true; reasons.insert("cancelled") }
        return EvidenceCollection(preview: scope, files: files, unreadReasons: unread, partialReasons: reasons, cancelled: cancelled)
    }
}
