import Foundation
@testable import OchesCore

func makeTempDirectory(_ name: String = UUID().uuidString) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oches-tests-\(name)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}
