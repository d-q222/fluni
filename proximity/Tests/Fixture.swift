import Foundation

private final class FixtureToken {}

/// Test data that works in both places the tests run: on a phone or simulator the file is a resource in
/// the test bundle (project.yml); in the macOS host package it isn't, so fall back to the source tree.
enum Fixture {
    static func data(_ fileName: String, sourcePath: URL) throws -> Data {
        let base = (fileName as NSString).deletingPathExtension, ext = (fileName as NSString).pathExtension
        if let url = Bundle(for: FixtureToken.self).url(forResource: base, withExtension: ext) {
            return try Data(contentsOf: url)
        }
        return try Data(contentsOf: sourcePath)
    }
}
