import Foundation

/// Test launches (the Mac tools in tools/, stress.py) pass these on the command line and read the
/// "[fluni]" stdout lines; they must start immediately with no onboarding.
enum LaunchMode {
    static let testKeys = ["-risk", "-speed", "-sources", "-encryption", "-inviteTimeout", "-rotate", "-riskAfter", "-skipOnboarding", "-demoPeer"]
    static var isTestLaunch: Bool { ProcessInfo.processInfo.arguments.contains { testKeys.contains($0) } }
    static var isUnitTestHost: Bool { ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil }
}
