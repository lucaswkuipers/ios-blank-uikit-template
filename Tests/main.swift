import CryptoKit
import Foundation

final class MockAppleProtocol: URLProtocol {
    static var responses: [Int] = []
    static var requests = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        let code = Self.responses.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: ["Retry-After": "1"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

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
    let legacyProject = try JSONDecoder().decode(Project.self, from: Data(#"{"name":"Test","bundleIdentifier":"com.lucaswkuipers.Test"}"#.utf8))
    try expect(legacyProject.route == .testflight, "Existing apps retain their verified delivery route")
    let shelfProject = try JSONDecoder().decode(Project.self, from: Data(#"{"name":"Test","bundleIdentifier":"com.lucaswkuipers.Test","delivery":"shelf"}"#.utf8))
    try expect(shelfProject.route == .shelf && shelfProject.route.successResult == "available-in-shelf", "Shelf delivery must wait for its own availability result")
    try expectFailure { _ = try JSONDecoder().decode(Project.self, from: Data(#"{"name":"Test","bundleIdentifier":"com.lucaswkuipers.Test","delivery":"unknown"}"#.utf8)) }
    try expect(skipsPushWorkflow("Scaffold [skip ci]"), "Publishing a scaffold must dispatch the skipped workflow")
    try expect(skipsPushWorkflow("Notes\n\n[SKIP ACTIONS]"), "Skip markers can be in the commit body")
    try expect(!skipsPushWorkflow("Implement counter"), "Ordinary commits must wait for their push workflow")
    let delivered = #"{"app":"Test","build":"5","result":"available-in-shelf","sourcesChanged":"false","team":"AR7T5G5Z83"}"#
    try expect(deliveryResult(logs: "log prefix \(delivered)", project: shelfProject)?["build"] == "5", "Read the matching app's delivery result")
    try expect(deliveryResult(logs: delivered.replacingOccurrences(of: "\"Test\"", with: "\"Other\""), project: shelfProject) == nil, "Another app's successful delivery cannot satisfy this publish")
    try expect(deliveryResult(logs: delivered.replacingOccurrences(of: "\"5\"", with: "\"invalid\""), project: shelfProject) == nil, "Malformed build identity must not report successful delivery")
    try expect(deliveryResult(logs: delivered.replacingOccurrences(of: "\"5\"", with: "\"9999.99.99\""), project: shelfProject) != nil, "The final valid build does not need another available build number")
    try expect(deliveryResult(logs: delivered, project: legacyProject) == nil, "Another route's success cannot satisfy this publish")
    try verifyPersonalSettings(personal, expectedBundle: "com.lucaswkuipers.Test")
    var otherTeam = personal
    otherTeam["DEVELOPMENT_TEAM"] = "OTHERTEAM1"
    try expectFailure { try verifyPersonalSettings(otherTeam, expectedBundle: "com.lucaswkuipers.Test") }
    var otherBundle = personal
    otherBundle["PRODUCT_BUNDLE_IDENTIFIER"] = "co.amo.Test"
    try expectFailure { try verifyPersonalSettings(otherBundle, expectedBundle: "co.amo.Test") }
    try expectFailure { try verifyPersonalSettings(personal, expectedBundle: "com.lucaswkuipers.Other") }

    let directProfile: [String: Any] = ["TeamIdentifier": ["AR7T5G5Z83"], "ProvisionedDevices": ["personal-iphone"], "Entitlements": ["application-identifier": "AR7T5G5Z83.com.lucaswkuipers.Test", "get-task-allow": false], "ExpirationDate": Date().addingTimeInterval(86400 * 30)]
    _ = try verifyDirectProfile(directProfile, bundle: "com.lucaswkuipers.Test", deviceUDID: "personal-iphone")
    for (key, value) in [("TeamIdentifier", ["OTHERTEAM1"] as Any), ("ProvisionedDevices", ["personal-iphone", "another-device"] as Any), ("ExpirationDate", Date() as Any), ("ProvisionsAllDevices", true as Any), ("Entitlements", ["application-identifier": "AR7T5G5Z83.com.lucaswkuipers.Test", "get-task-allow": true] as Any)] {
        var invalid = directProfile
        invalid[key] = value
        try expectFailure { _ = try verifyDirectProfile(invalid, bundle: "com.lucaswkuipers.Test", deviceUDID: "personal-iphone") }
    }
    try expectFailure { _ = try verifyDirectProfile(directProfile, bundle: "com.lucaswkuipers.Other", deviceUDID: "personal-iphone") }
    try expectFailure { _ = try verifyDirectProfile(directProfile, bundle: "com.lucaswkuipers.Test", deviceUDID: "another-device") }

    let payloadExpiry = try JSONSerialization.data(withJSONObject: ["exp": 1000]).base64EncodedString().replacingOccurrences(of: "=", with: "")
    let download = URL(string: "https://release-assets.githubusercontent.com/artifact?se=2099-01-01T00:00:00Z&jwt=header.\(payloadExpiry).signature")!
    try expect(try shelfDownloadExpiration(download) == Date(timeIntervalSince1970: 1000), "GitHub JWT can expire before the blob signature")
    try expectFailure { _ = try shelfDownloadExpiration(URL(string: "https://evil.invalid/artifact?se=2099-01-01T00:00:00Z&jwt=header.\(payloadExpiry).signature")!) }
    try expectFailure { _ = try shelfDownloadExpiration(URL(string: "https://release-assets.githubusercontent.com/artifact?se=2099-01-01T00:00:00Z")!) }

    try PersonalRepository(nameWithOwner: "lucaswkuipers/Example", isPrivate: true, url: "https://github.com/lucaswkuipers/Example").verify(name: "Example")
    try expectFailure { try PersonalRepository(nameWithOwner: "lucaswkuipers/Example", isPrivate: false, url: "").verify(name: "Example") }
    try expectFailure { try PersonalRepository(nameWithOwner: "wesprint-io/Example", isPrivate: true, url: "").verify(name: "Example") }
    try expectFailure { try PersonalRepository(nameWithOwner: "lucaswkuipers/Another", isPrivate: true, url: "").verify(name: "Example") }
    try verifyPersonalRemote("git@github.com-personal:lucaswkuipers/Example.git", name: "Example")
    try verifyPersonalRemote("https://github.com/lucaswkuipers/Example.git", name: "Example")
    try expectFailure { try verifyPersonalRemote("git@github.com:wesprint-io/Example.git", name: "Example") }
    try expectFailure { try verifyPersonalRemote("https://github.com/other/Example.git", name: "Example") }
    try expectFailure { try verifyPersonalRemote("https://github.com.evil.invalid/lucaswkuipers/Example.git", name: "Example") }
    let localOptions = try Options(["--local-only", "--icon", "bolt"], allowed: ["--local-only", "--icon"])
    try expect(localOptions.localOnly && localOptions.values["--icon"] == "bolt", "Local-only creation must skip remote setup without consuming the next argument")

    try expect(try nextBuildNumber(nil) == "1", "Initial build number")
    try expect(try nextBuildNumber("42") == "43", "Integer build number")
    try expect(try nextBuildNumber("42.9.1") == "43", "Dotted build number")
    try expect(try nextBuildNumber("9999.98.99") == "9999.99.0", "Build number rollover")
    try expectFailure { _ = try nextBuildNumber("9999.99.99") }
    try expectFailure { _ = try nextBuildNumber("1.bad.3") }

    let counters = temporary.appendingPathComponent("delivery")
    let firstDirect = try ShelfDeliveryState.reserve(bundle: "com.lucaswkuipers.Test", commit: "first", minimum: "4", directory: counters)
    let retriedDirect = try ShelfDeliveryState.reserve(bundle: "com.lucaswkuipers.Test", commit: "first", minimum: "4", directory: counters)
    try expect(firstDirect.build == "4" && retriedDirect.build == "4", "Direct retries must retain their reserved build")
    let flightAfterDirect = try reserveBuildNumber(bundle: "com.lucaswkuipers.Test", minimum: "4", directory: counters.appendingPathComponent("build-numbers"))
    try expect(flightAfterDirect == "5", "TestFlight must advance past the last direct build")
    let directAfterFlight = try ShelfDeliveryState.reserve(bundle: "com.lucaswkuipers.Test", commit: "second", minimum: "5", directory: counters)
    try expect(directAfterFlight.build == "6", "Direct delivery must advance past a reserved TestFlight build")
    let renewedDirect = try ShelfDeliveryState.reserve(bundle: "com.lucaswkuipers.Test", commit: "second", minimum: "7", directory: counters)
    try expect(renewedDirect.build == "7", "Re-signing the same commit must be able to advance past the expired published build")
    try expectFailure { _ = try reserveBuildNumber(bundle: "../escape", minimum: "1", directory: counters) }
    try "corrupted".write(to: counters.appendingPathComponent("build-numbers/com.lucaswkuipers.Test.json"), atomically: true, encoding: .utf8)
    try expectFailure { _ = try reserveBuildNumber(bundle: "com.lucaswkuipers.Test", minimum: "1", directory: counters.appendingPathComponent("build-numbers")) }

    let uploads = Data(#"{"data":[{"attributes":{"cfBundleVersion":"1","state":{"state":"COMPLETE","errors":[]}}},{"attributes":{"cfBundleVersion":"2","state":{"state":"PROCESSING","errors":[]}}},{"attributes":{"cfBundleVersion":"3","state":{"state":"FAILED","errors":[{"code":"ITMS-TEST","description":"Invalid binary"}]}}}]}"#.utf8)
    try expect(try buildUploadStatus(uploads, buildNumber: "2")?.state == "PROCESSING", "Read the requested upload while the build is not yet visible")
    let failedUpload = try buildUploadStatus(uploads, buildNumber: "3")
    try expect(failedUpload?.state == "FAILED" && failedUpload?.details.contains("Invalid binary") == true, "Preserve early processing failure details")
    try expect(try buildUploadStatus(uploads, buildNumber: "4") == nil, "Another build's status must not be reused")
    try expectFailure { _ = try buildUploadStatus(Data(#"{"data":[{"attributes":{"cfBundleVersion":"2","state":null}}]}"#.utf8), buildNumber: "2") }

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

    let providerJSON: [String: Any] = ["provider": ["publicProviderId": configuration.issuer], "user": ["emailAddress": configuration.testerEmail]]
    let provider = try JSONDecoder().decode(ProviderSession.self, from: JSONSerialization.data(withJSONObject: providerJSON))
    try provider.verify(configuration: configuration)
    let otherProviderJSON: [String: Any] = ["provider": ["publicProviderId": UUID().uuidString], "user": ["emailAddress": configuration.testerEmail]]
    let otherProvider = try JSONDecoder().decode(ProviderSession.self, from: JSONSerialization.data(withJSONObject: otherProviderJSON))
    try expectFailure { try otherProvider.verify(configuration: configuration) }
    let otherUserJSON: [String: Any] = ["provider": ["publicProviderId": configuration.issuer], "user": ["emailAddress": "someone@example.com"]]
    let otherUser = try JSONDecoder().decode(ProviderSession.self, from: JSONSerialization.data(withJSONObject: otherUserJSON))
    try expectFailure { try otherUser.verify(configuration: configuration) }

    let network = URLSessionConfiguration.ephemeral
    network.protocolClasses = [MockAppleProtocol.self]
    let session = URLSession(configuration: network)
    defer { session.invalidateAndCancel() }
    var request = URLRequest(url: URL(string: "https://apple-tests.invalid/test")!)
    request.httpMethod = "GET"
    MockAppleProtocol.responses = [503, 200]
    MockAppleProtocol.requests = 0
    _ = try appleRequest(request, session: session)
    try expect(MockAppleProtocol.requests == 2, "Transient reads should retry")
    request.httpMethod = "POST"
    MockAppleProtocol.responses = [503]
    MockAppleProtocol.requests = 0
    try expectFailure { _ = try appleRequest(request, session: session) }
    try expect(MockAppleProtocol.requests == 1, "Uncertain mutations must not retry blindly")
    request.httpMethod = "GET"
    MockAppleProtocol.responses = [403]
    MockAppleProtocol.requests = 0
    try expectFailure { _ = try appleRequest(request, session: session) }
    try expect(MockAppleProtocol.requests == 1, "Authorization errors must not retry")

    let stdout = try run("/bin/sh", ["-c", "printf '{\"valid\":true}'; printf 'warning' >&2"], log: nil, separateError: true)
    try expect(stdout == "{\"valid\":true}", "Warnings must not corrupt JSON stdout")

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

    let hiddenSources = sources.appendingPathComponent("App")
    try files.createDirectory(at: hiddenSources, withIntermediateDirectories: true)
    let hiddenSource = hiddenSources.appendingPathComponent("App.swift")
    try "first".write(to: hiddenSource, atomically: true, encoding: .utf8)
    guard chflags(hiddenSources.path, UInt32(UF_HIDDEN)) == 0 else { throw CommandError(message: "Cannot set Finder hidden flag for regression test.") }
    let hiddenBefore = try sourceFingerprint(sources)
    try "changed".write(to: hiddenSource, atomically: true, encoding: .utf8)
    try expect(try sourceFingerprint(sources) != hiddenBefore, "Finder-hidden app folders must still detect source edits")
    let empty = temporary.appendingPathComponent("Empty")
    try files.createDirectory(at: empty, withIntermediateDirectories: true)
    try expectFailure { _ = try sourceFingerprint(empty) }

    let state = DeliveryState(fingerprint: second, appID: "123", bundleIdentifier: "com.lucaswkuipers.Test", buildNumber: "1", archivePath: "/tmp/test.xcarchive", phase: "upload-started")
    let stateURL = temporary.appendingPathComponent("state.json")
    try state.save(stateURL)
    let saved = try JSONDecoder().decode(DeliveryState.self, from: Data(contentsOf: stateURL))
    try expect(saved.phase == "upload-started" && saved.buildNumber == "1", "Interrupted upload must retain its build identity")
    print("Passed account/provider guards, safe HTTP retries, clean JSON stdout, JWT signing, build numbering, upload processing, source fingerprints, and resumable state.")
} catch {
    status(error.localizedDescription)
    exit(1)
}
