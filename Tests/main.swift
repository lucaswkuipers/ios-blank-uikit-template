import CryptoKit
import Foundation

func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw CommandError(message: message) }
}

func expectFailure(_ operation: () throws -> Void) throws {
    do { try operation() }
    catch { return }
    throw CommandError(message: "Operation unexpectedly succeeded")
}

func decodeBase64URL(_ text: String) -> Data {
    let base = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    return Data(base64Encoded: base + String(repeating: "=", count: (4 - base.count % 4) % 4))!
}

do {
    let temporary = files.temporaryDirectory.appendingPathComponent("uikit-app-tests-\(UUID().uuidString)")
    try files.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: temporary) }

    let personal: [String: Any] = ["DEVELOPMENT_TEAM": "AR7T5G5Z83", "PRODUCT_BUNDLE_IDENTIFIER": "com.lucaswkuipers.Test", "CODE_SIGN_STYLE": "Automatic"]
    try verifyPersonalSettings(personal, expectedBundle: "com.lucaswkuipers.Test")
    var otherTeam = personal
    otherTeam["DEVELOPMENT_TEAM"] = "OTHERTEAM1"
    try expectFailure { try verifyPersonalSettings(otherTeam, expectedBundle: "com.lucaswkuipers.Test") }
    var otherBundle = personal
    otherBundle["PRODUCT_BUNDLE_IDENTIFIER"] = "co.amo.Test"
    try expectFailure { try verifyPersonalSettings(otherBundle, expectedBundle: "co.amo.Test") }
    try expectFailure { try verifyPersonalSettings(personal, expectedBundle: "com.lucaswkuipers.Other") }

    try expect(try nextBuildNumber(nil) == "1", "Initial build number")
    try expect(try nextBuildNumber("42") == "43", "Integer build number")
    try expect(try nextBuildNumber("42.9.1") == "43", "Dotted build number")
    try expect(try nextBuildNumber("9999.98.99") == "9999.99.0", "Build number rollover")
    try expectFailure { _ = try nextBuildNumber("9999.99.99") }
    try expectFailure { _ = try nextBuildNumber("1.bad.3") }

    let key = P256.Signing.PrivateKey()
    let keyPath = temporary.appendingPathComponent("test.p8")
    try key.pemRepresentation.write(to: keyPath, atomically: true, encoding: .utf8)
    let configuration = TestFlightConfiguration(keyID: "123456789A", issuer: UUID().uuidString, keyPath: keyPath.path, testerEmail: "owner@example.com", accountBundle: "com.lucaswkuipers.Anchor")
    let client = try AppStoreClient(configuration: configuration)
    let token = try client.token().split(separator: ".").map(String.init)
    try expect(token.count == 3, "JWT segments")
    let signature = try P256.Signing.ECDSASignature(rawRepresentation: decodeBase64URL(token[2]))
    try expect(key.publicKey.isValidSignature(signature, for: Data((token[0] + "." + token[1]).utf8)), "JWT signature")
    let payload = try JSONSerialization.jsonObject(with: decodeBase64URL(token[1])) as! [String: Any]
    try expect(payload["iss"] as? String == configuration.issuer, "JWT issuer")
    try expect(payload["aud"] as? String == "appstoreconnect-v1", "JWT audience")
    try expect((payload["exp"] as! Int) - (payload["iat"] as! Int) == 600, "JWT lifetime")
    let workConfiguration = TestFlightConfiguration(keyID: "123456789A", issuer: configuration.issuer, keyPath: keyPath.path, testerEmail: "user@amo.co", accountBundle: "com.lucaswkuipers.Anchor")
    try expectFailure { try workConfiguration.validate() }

    let sources = temporary.appendingPathComponent("Sources")
    try files.createDirectory(at: sources, withIntermediateDirectories: true)
    let source = sources.appendingPathComponent("ViewController.swift")
    try "first".write(to: source, atomically: true, encoding: .utf8)
    let first = try sourceFingerprint(sources)
    try "second".write(to: source, atomically: true, encoding: .utf8)
    let second = try sourceFingerprint(sources)
    try expect(first != second, "Changed code must produce a new delivery")
    let userData = sources.appendingPathComponent("xcuserdata")
    try files.createDirectory(at: userData, withIntermediateDirectories: true)
    try "noise".write(to: userData.appendingPathComponent("state"), atomically: true, encoding: .utf8)
    try expect(try sourceFingerprint(sources) == second, "Xcode user state must not produce duplicate deliveries")

    let state = DeliveryState(fingerprint: second, appID: "123", bundleIdentifier: "com.lucaswkuipers.Test", buildNumber: "1", archivePath: "/tmp/test.xcarchive", phase: "upload-started")
    let stateURL = temporary.appendingPathComponent("state.json")
    try state.save(stateURL)
    let saved = try JSONDecoder().decode(DeliveryState.self, from: Data(contentsOf: stateURL))
    try expect(saved.phase == "upload-started" && saved.buildNumber == "1", "Interrupted upload must retain its build identity")
    print("Passed personal-account guards, build numbering, JWT signing, source fingerprinting, and delivery-state persistence.")
} catch {
    status(error.localizedDescription)
    exit(1)
}
