import CryptoKit
import Foundation

func testShelfInstalls(directory: URL) throws {
    let package = directory.appendingPathComponent("shelf-package.ipa")
    let data = Data("signed-package-fixture".utf8)
    try data.write(to: package)
    let application = ShelfApplication(name: "Test", bundleIdentifier: "com.lucaswkuipers.Test", version: "2.0", build: "10", minimumOSVersion: "26.0", profileExpiration: Date().addingTimeInterval(86400 * 30), sourceCommit: "commit", sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), size: data.count, packageAssetID: 123, publishedAt: Date())

    func installed(_ apps: [[String: Any]]) throws -> ShelfInstalledApps {
        try JSONDecoder().decode(ShelfInstalledApps.self, from: JSONSerialization.data(withJSONObject: ["result": ["apps": apps]]))
    }

    func app(version: String, build: String) -> [String: Any] {
        ["bundleIdentifier": application.bundleIdentifier, "version": version, "bundleVersion": build, "appClip": false]
    }

    try expect(try installed([]).needsInstall(application), "A missing app must be installed, independently of Keychain receipts")
    try expect(try installed([app(version: "1.0", build: "99")]).needsInstall(application), "A newer marketing version can restart its build sequence")
    try expect(try installed([app(version: "2.0", build: "9")]).needsInstall(application), "Builds must compare numerically")
    try expect(try !installed([app(version: "2.0", build: "10")]).needsInstall(application), "An unchanged build must not be reinstalled on each refresh")
    try expect(try !installed([app(version: "2.0", build: "11")]).needsInstall(application), "A newer device build must not be downgraded")
    try expect(try !installed([app(version: "3.0", build: "1")]).needsInstall(application), "A newer device version must not be downgraded")
    var other = app(version: "2.0", build: "10")
    other["bundleIdentifier"] = "com.lucaswkuipers.Another"
    try expect(try installed([other]).needsInstall(application), "Another app cannot satisfy installation")
    var clip = app(version: "2.0", build: "10")
    clip["appClip"] = true
    try expect(try installed([clip]).needsInstall(application), "An app clip is not the full app")
    var unknown = app(version: "2.0", build: "10")
    unknown.removeValue(forKey: "bundleVersion")
    try expectFailure { _ = try installed([unknown]).needsInstall(application) }
    try expectFailure { _ = try installed([app(version: "2.0", build: "unknown")]).needsInstall(application) }
    try expectFailure { _ = try installed([app(version: "2.0", build: "9"), app(version: "2.0", build: "11")]).needsInstall(application) }
    try expectFailure { _ = try JSONDecoder().decode(ShelfInstalledApps.self, from: Data(#"{"error":{"message":"Device unavailable"}}"#.utf8)) }
    try expectFailure { _ = try JSONDecoder().decode(ShelfInstalledApps.self, from: Data(#"{"result":{}}"#.utf8)) }

    try verifyShelfPackage(package, application: application)
    try Data(repeating: 0, count: data.count).write(to: package)
    try expectFailure { try verifyShelfPackage(package, application: application) }
    try data.dropLast().write(to: package)
    try expectFailure { try verifyShelfPackage(package, application: application) }

    let bundle = directory.appendingPathComponent("Test.app")
    try files.createDirectory(at: bundle, withIntermediateDirectories: true)
    try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.lucaswkuipers.Other", "CFBundleVersion": "10", "CFBundleShortVersionString": "2.0"], format: .xml, options: 0).write(to: bundle.appendingPathComponent("Info.plist"))
    try expectFailure { try verifyShelfInstall(bundle, application: application, deviceUDID: "personal-iphone") }
}
