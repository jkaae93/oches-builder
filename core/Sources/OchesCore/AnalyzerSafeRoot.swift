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
    func read(relativePath: String, maximumBytes: Int, beforeFinalOpen: (() -> Void)? = nil, beforeFinalStat: (() -> Void)? = nil) throws -> Data {
        guard maximumBytes > 0, maximumBytes <= 1_048_576,
              !relativePath.hasPrefix("/"), !relativePath.utf8.contains(0) else { throw AccessError.invalidPath }
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
