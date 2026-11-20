import CryptoKit
import Foundation
import ImageIO

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

func shelfIconFixture(pixels: Int, noisy: Bool) throws -> String {
    var bytes = Data(count: pixels * pixels * 4)
    var random: UInt32 = 1
    for index in bytes.indices {
        random = random &* 1664525 &+ 1013904223
        bytes[index] = index % 4 == 3 ? 255 : noisy ? UInt8(truncatingIfNeeded: random >> 16) : 128
    }
    let image = CGImage(width: pixels, height: pixels, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: pixels * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: CGDataProvider(data: bytes as CFData)!, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    try expect(CGImageDestinationFinalize(destination), "Create a catalog icon fixture")
    return (data as Data).base64EncodedString()
}

func decodeBase64URL(_ text: String) -> Data {
    let base = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    return Data(base64Encoded: base + String(repeating: "=", count: (4 - base.count % 4) % 4))!
}

do {
    let temporary = files.temporaryDirectory.appendingPathComponent("uikit-app-tests-\(UUID().uuidString)")
    try files.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: temporary) }

    try testShelfNotifications(directory: temporary)
    try testShelfInstalls(directory: temporary)
    try testShelfSharing(directory: temporary)
    try testShelfRequests(directory: temporary)

    let signingProject = temporary.appendingPathComponent("Example.xcodeproj")
    try files.createDirectory(at: signingProject, withIntermediateDirectories: true)
    let signingObjects: [String: [String: Any]] = [
        "app": ["isa": "PBXNativeTarget", "name": "Example", "productType": "com.apple.product-type.application", "dependencies": ["widgetDependency", "frameworkDependency"]],
        "widgetDependency": ["target": "widget"],
        "widget": ["isa": "PBXNativeTarget", "name": "Widget", "productType": "com.apple.product-type.app-extension", "dependencies": ["watchDependency"]],
        "watchDependency": ["target": "watch"],
        "watch": ["isa": "PBXNativeTarget", "name": "Watch", "productType": "com.apple.product-type.application.watchapp2", "dependencies": []],
        "frameworkDependency": ["target": "framework"],
        "framework": ["isa": "PBXNativeTarget", "name": "Framework", "productType": "com.apple.product-type.framework", "dependencies": []],
        "unrelated": ["isa": "PBXNativeTarget", "name": "OtherApp", "productType": "com.apple.product-type.application", "dependencies": []]
    ]
    try PropertyListSerialization.data(fromPropertyList: ["objects": signingObjects], format: .xml, options: 0).write(to: signingProject.appendingPathComponent("project.pbxproj"))
    try expect(try directEmbeddedTargets(project: signingProject, name: "Example") == ["Watch", "Widget"], "Sign only reachable embedded apps and extensions, excluding frameworks and unrelated targets")
    try expect(try directProfileVariable("com.lucaswkuipers.Example.widget") == "SHELF_PROFILE_com_lucaswkuipers_Example_widget", "Bundle signing variables must match Xcode identifier expansion")
    try expectFailure { _ = try directProfileVariable("com.example.\nInjected = value") }

    let unity = temporary.appendingPathComponent("UnitySource")
    try files.createDirectory(at: unity.appendingPathComponent("ProjectSettings"), withIntermediateDirectories: true)
    try files.createDirectory(at: unity.appendingPathComponent("Library"), withIntermediateDirectories: true)
    try "2022.3.7f1".write(to: unity.appendingPathComponent("ProjectSettings/ProjectVersion.txt"), atomically: true, encoding: .utf8)
    let unityFingerprint = try sourceFingerprint(unity)
    try "cache".write(to: unity.appendingPathComponent("Library/generated"), atomically: true, encoding: .utf8)
    try expect(try sourceFingerprint(unity) == unityFingerprint, "Unity-generated caches must not change the source fingerprint")
    try "2022.3.8f1".write(to: unity.appendingPathComponent("ProjectSettings/ProjectVersion.txt"), atomically: true, encoding: .utf8)
    try expect(try sourceFingerprint(unity) != unityFingerprint, "Unity project settings remain part of the source fingerprint")

    let noisyIcon = try shelfIconFixture(pixels: 128, noisy: true)
    let catalogApps = (0..<10).map { index in
        ShelfApplication(name: "App \(index)", bundleIdentifier: "com.lucaswkuipers.App\(index)", version: "1.0", build: "1", minimumOSVersion: "27.0", profileExpiration: .distantFuture, sourceCommit: "commit", sha256: "digest", size: 42, packageAssetID: index + 1, publishedAt: .distantPast, manifestAssetID: index + 100, installExpiration: .distantFuture, iconPNG: noisyIcon)
    }
    let oversizedCatalog = ShelfCatalog(schema: 1, applications: catalogApps, invitation: "https://example.com/invite")
    let compactCatalogData = try shelfCatalogBody(oversizedCatalog, encoder: JSONEncoder())
    let compactCatalog = try JSONDecoder().decode(ShelfCatalog.self, from: compactCatalogData)
    try expect(compactCatalogData.count <= 100_000, "Catalog thumbnails must leave headroom below GitHub's release body limit")
    try expect(compactCatalog.applications.map(\.manifestAssetID) == catalogApps.map(\.manifestAssetID) && compactCatalog.invitation == oversizedCatalog.invitation, "Compacting icons preserves installation links and the invitation")
    let pruneTime = Date()
    let manifests = (0..<1000).map { index in
        ShelfAsset(id: index, name: "manifest-\(index).plist", created_at: ISO8601DateFormatter().string(from: pruneTime.addingTimeInterval(-Double(index) * 2)), size: 1, digest: nil)
    }
    let pruned = Set(staleShelfAssets(manifests, active: [999, 5], now: pruneTime).map(\.id))
    try expect(!pruned.contains(999) && !pruned.contains(5), "Pruning keeps manifests the catalog still links")
    try expect(!pruned.contains(0) && !pruned.contains(299) && pruned.contains(301) && pruned.contains(998), "Pruning keeps recent manifests and removes old superseded ones")
    try expect(manifests.count - pruned.count <= 302, "Pruning leaves room below GitHub's asset limit")
    try expect(staleShelfAssets(Array(manifests.prefix(50)), active: [], now: pruneTime).isEmpty, "Recent superseded manifests stay for clients mid-install")
    for app in compactCatalog.applications {
        try expect(CGImageSourceCreateWithData(Data(base64Encoded: app.iconPNG!)! as CFData, nil) != nil, "Compacted icons remain decodable images")
    }
    let catalogEncoder = JSONEncoder()
    catalogEncoder.dateEncodingStrategy = .iso8601
    catalogEncoder.outputFormatting = [.sortedKeys]
    let catalogDecoder = JSONDecoder()
    catalogDecoder.dateDecodingStrategy = .iso8601
    let smallCatalog = ShelfCatalog(schema: 1, applications: [catalogApps[0]], invitation: nil)
    try expect(try shelfCatalogBody(smallCatalog, encoder: catalogEncoder) == catalogEncoder.encode(smallCatalog), "Catalogs below the budget retain their original thumbnails")
    var visionApps = Array(catalogApps.prefix(5))
    for index in visionApps.indices {
        visionApps[index].platform = ShelfPlatform.visionOS.catalogValue
    }
    let unsharedCatalog = ShelfCatalog(schema: 1, applications: [], invitation: nil, visionApplications: visionApps, ownerApplications: Array(catalogApps.suffix(5)))
    let unsharedBody = try JSONDecoder().decode(ShelfCatalog.self, from: shelfCatalogBody(unsharedCatalog, encoder: JSONEncoder()))
    try expect((unsharedBody.visionApplications ?? []).count == 5 && (unsharedBody.ownerApplications ?? []).count == 5 && (unsharedBody.visionApplications! + unsharedBody.ownerApplications!).allSatisfy { $0.iconPNG != nil }, "Owner-only and visionOS icons shrink to fit the release body too")

    let plainIcon = try shelfIconFixture(pixels: 128, noisy: false)
    let shelfApp = ShelfApplication(name: "AppShelf", bundleIdentifier: "com.lucaswkuipers.AppShelf", version: "1.0", build: "30", minimumOSVersion: "15.0", profileExpiration: .distantFuture, sourceCommit: "commit", sha256: "digest", size: 42, packageAssetID: 5000, publishedAt: .distantPast, manifestAssetID: 6000, installExpiration: .distantFuture, iconPNG: plainIcon)
    let shelfVisionApp = ShelfApplication(name: "AppShelf", bundleIdentifier: "com.lucaswkuipers.AppShelf", version: "1.0", build: "30", minimumOSVersion: "2.0", profileExpiration: .distantFuture, sourceCommit: "commit", sha256: "digest", size: 42, packageAssetID: 5001, publishedAt: .distantPast, iconPNG: plainIcon, platform: ShelfPlatform.visionOS.catalogValue)
    let manyApps = (0..<400).map { index in
        ShelfApplication(name: "App \(index)", bundleIdentifier: "com.lucaswkuipers.Many\(index)", version: "1.0", build: "1", minimumOSVersion: "27.0", profileExpiration: .distantFuture, sourceCommit: String(repeating: "c", count: 40), sha256: String(repeating: "d", count: 64), size: 42, packageAssetID: 10_000 + index, publishedAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(index) * 60), manifestAssetID: 766_000_000 + index, installExpiration: Date(timeIntervalSince1970: 1_800_000_000), iconPNG: plainIcon, notificationTitle: "Update available", deviceSet: "0123456789abcdef", silent: false, releaseNotes: ["Change \(index)"])
    }
    let largeCatalog = ShelfCatalog(schema: 1, applications: [shelfApp] + manyApps, invitation: "https://example.com/invite", visionApplications: [shelfVisionApp])
    let largeBody = try shelfCatalogBody(largeCatalog, encoder: catalogEncoder)
    let largeListed = try catalogDecoder.decode(ShelfCatalog.self, from: largeBody)
    let keptApps = largeListed.applications.filter { $0.bundleIdentifier != shelfApp.bundleIdentifier }
    try expect(largeBody.count <= 100_000, "Hundreds of apps still fit GitHub's release body")
    try expect(largeListed.applications.first?.packageAssetID == shelfApp.packageAssetID && largeListed.visionApplications?.map(\.packageAssetID) == [shelfVisionApp.packageAssetID], "Older clients can always update AppShelf")
    try expect(keptApps.count > 50 && keptApps.count < manyApps.count && keptApps.map(\.packageAssetID) == manyApps.suffix(keptApps.count).map(\.packageAssetID), "A full release body leaves out the longest-unchanged apps first")
    let unlinkedCatalog = largeCatalog.mapApplications { application in
        var application = application
        application.manifestAssetID = nil
        application.installExpiration = nil
        return application
    }
    let unlinkedListed = Set(try catalogDecoder.decode(ShelfCatalog.self, from: shelfCatalogBody(unlinkedCatalog, encoder: catalogEncoder)).applications.map(\.packageAssetID))
    let relinkedCatalog = unlinkedCatalog.mapApplications { application in
        var application = application
        if unlinkedListed.contains(application.packageAssetID) {
            application.manifestAssetID = 9_999_999_999
            application.installExpiration = .distantFuture
        }
        return application
    }
    let relinkedListed = Set(try catalogDecoder.decode(ShelfCatalog.self, from: shelfCatalogBody(relinkedCatalog, encoder: catalogEncoder)).applications.map(\.packageAssetID))
    try expect(relinkedListed.isSuperset(of: unlinkedListed), "Install links for listed apps never push those apps out of the release body")
    let listedPackages = Set(largeListed.applications.map(\.packageAssetID))
    let leftOutUnlinked = largeCatalog.mapApplications { application in
        var application = application
        if !listedPackages.contains(application.packageAssetID) {
            application.manifestAssetID = nil
            application.installExpiration = nil
        }
        return application
    }
    try expect(Set(try catalogDecoder.decode(ShelfCatalog.self, from: shelfCatalogBody(leftOutUnlinked, encoder: catalogEncoder)).applications.map(\.packageAssetID)) == listedPackages, "Apps left out of the release body keep no room for install links they never get")
    var pointedCatalog = largeCatalog
    pointedCatalog.catalogAsset = ShelfCatalogAsset(id: 990, sha256: "previous", size: 1)
    let assetData = try shelfCatalogAsset(pointedCatalog, encoder: catalogEncoder)
    let assetFile = temporary.appendingPathComponent("catalog.json.gz")
    try assetData.write(to: assetFile)
    try run("/usr/bin/gzip", ["--test", assetFile.path], log: nil)
    let completeCatalog = try catalogDecoder.decode(ShelfCatalog.self, from: shelfGunzip(assetData))
    try expect(completeCatalog.catalogAsset == nil && (completeCatalog.applications + (completeCatalog.visionApplications ?? [])).allSatisfy { $0.manifestAssetID == nil && $0.installExpiration == nil }, "The catalog asset leaves out the install links that change every few minutes")
    try expect(completeCatalog.applications.count == largeCatalog.applications.count && completeCatalog.applications.allSatisfy { $0.iconPNG == plainIcon } && completeCatalog.invitation == largeCatalog.invitation, "The catalog asset keeps every app with its original icon")
    let linkedCatalog = shelfCatalog(completeCatalog, linkedFrom: largeListed)
    let listedLinks = Dictionary(uniqueKeysWithValues: largeListed.applications.map { ($0.packageAssetID, $0.manifestAssetID) })
    try expect(linkedCatalog.applications.allSatisfy { $0.manifestAssetID == listedLinks[$0.packageAssetID] ?? nil } && linkedCatalog.visionApplications?.first?.manifestAssetID == nil, "Install links come back from the release body for the packages it lists")
    try expect(pointedCatalog.linkedAssetIDs.contains(990) && !staleShelfAssets(manifests, active: pointedCatalog.linkedAssetIDs, now: pruneTime).contains { $0.id == 990 }, "Pruning keeps the catalog asset the release body names")
    let catalogAssets = (0..<3).map { index in
        ShelfAsset(id: 2000 + index, name: "catalog-\(index).json.gz", created_at: ISO8601DateFormatter().string(from: pruneTime.addingTimeInterval(-86400 * Double(index + 1))), size: 1, digest: nil)
    }
    try expect(Set(staleShelfAssets(catalogAssets, active: [2000], now: pruneTime).map(\.id)) == [2002], "Pruning keeps the catalog asset replaced last for clients that read the body just before")
    try expectFailure { _ = try shelfGunzip(Data("{\"schema\":1}".utf8)) }
    try expect(!String(decoding: try JSONEncoder().encode(smallCatalog), as: UTF8.self).contains("visionApplications"), "Catalogs without visionOS apps keep their existing shape")
    var platformCatalog = smallCatalog
    var visionApp = catalogApps[1]
    visionApp.platform = ShelfPlatform.visionOS.catalogValue
    platformCatalog.setApplications([visionApp], for: .visionOS)
    let decodedPlatforms = try JSONDecoder().decode(ShelfCatalog.self, from: JSONEncoder().encode(platformCatalog))
    try expect(decodedPlatforms.applications(for: .iOS).map(\.bundleIdentifier) == [catalogApps[0].bundleIdentifier] && decodedPlatforms.applications(for: .visionOS).map(\.platform) == ["visionOS"], "visionOS apps stay out of the list older iPhone clients read")
    let ownerProject = try JSONDecoder().decode(Project.self, from: Data(#"{"name":"Example","bundleIdentifier":"\#(catalogApps[0].bundleIdentifier)","ownerOnly":true}"#.utf8))
    let sharedProject = try JSONDecoder().decode(Project.self, from: Data(#"{"name":"Example","bundleIdentifier":"\#(catalogApps[0].bundleIdentifier)"}"#.utf8))
    var ownerCatalog = smallCatalog
    ownerCatalog.setApplications([catalogApps[0]], for: ownerProject, platform: .iOS)
    try expect(ownerCatalog.applications.isEmpty && ownerCatalog.applications(for: ownerProject, platform: .iOS).map(\.bundleIdentifier) == [catalogApps[0].bundleIdentifier], "Owner-only apps leave the list older clients, announcements and re-signing read")
    ownerCatalog.setApplications([catalogApps[0]], for: sharedProject, platform: .iOS)
    try expect(ownerCatalog.applications.map(\.bundleIdentifier) == [catalogApps[0].bundleIdentifier] && ownerCatalog.ownerApplications?.isEmpty == true, "Apps opened to everyone leave the owner-only list")
    let visionProject = try JSONDecoder().decode(Project.self, from: Data(#"{"name":"Blockport","bundleIdentifier":"com.lucaswkuipers.blockport.vision","product":"Blockport Vision","platforms":["visionOS"],"publishOnRequest":true}"#.utf8))
    try expect(visionProject.productName == "Blockport Vision" && visionProject.shelfPlatforms == [.visionOS] && ShelfPlatform.visionOS.destination == "generic/platform=visionOS", "Projects choose their product and shelf platforms")

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
    _ = try verifyDirectProfile(directProfile, bundle: "com.lucaswkuipers.Test", provisioning: .exactly(["personal-iphone"]))
    for (key, value) in [("TeamIdentifier", ["OTHERTEAM1"] as Any), ("ProvisionedDevices", ["personal-iphone", "another-device"] as Any), ("ExpirationDate", Date() as Any), ("ProvisionsAllDevices", true as Any), ("Entitlements", ["application-identifier": "AR7T5G5Z83.com.lucaswkuipers.Test", "get-task-allow": true] as Any)] {
        var invalid = directProfile
        invalid[key] = value
        try expectFailure { _ = try verifyDirectProfile(invalid, bundle: "com.lucaswkuipers.Test", provisioning: .exactly(["personal-iphone"])) }
    }
    try expectFailure { _ = try verifyDirectProfile(directProfile, bundle: "com.lucaswkuipers.Other", provisioning: .exactly(["personal-iphone"])) }
    try expectFailure { _ = try verifyDirectProfile(directProfile, bundle: "com.lucaswkuipers.Test", provisioning: .exactly(["another-device"])) }
    try expectFailure { _ = try verifyDirectProfile(directProfile, bundle: "com.lucaswkuipers.Test", provisioning: .exactly(["personal-iphone", "friend-iphone"])) }
    var sharedProfile = directProfile
    sharedProfile["ProvisionedDevices"] = ["friend-iphone", "personal-iphone"]
    _ = try verifyDirectProfile(sharedProfile, bundle: "com.lucaswkuipers.Test", provisioning: .exactly(["personal-iphone", "friend-iphone"]))
    try expectFailure { _ = try verifyDirectProfile(sharedProfile, bundle: "com.lucaswkuipers.Test", provisioning: .exactly(["personal-iphone"])) }
    _ = try verifyDirectProfile(sharedProfile, bundle: "com.lucaswkuipers.Test", provisioning: .including("FRIEND-IPHONE"))
    try expectFailure { _ = try verifyDirectProfile(sharedProfile, bundle: "com.lucaswkuipers.Test", provisioning: .including("stranger-iphone")) }
    sharedProfile["ProvisionedDevices"] = ["personal-iphone", "personal-iphone"]
    try expectFailure { _ = try verifyDirectProfile(sharedProfile, bundle: "com.lucaswkuipers.Test", provisioning: .exactly(["personal-iphone", "friend-iphone"])) }

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
    let automaticOptions = try Options(["--automatic"], allowed: ["--automatic", "--device"])
    try expect(automaticOptions.automatic && automaticOptions.values.isEmpty, "Background share runs are marked without taking a value")

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

    let iconRoot = temporary.appendingPathComponent("IconApp")
    let iconSet = iconRoot.appendingPathComponent("IconApp/Assets.xcassets/AppIcon.appiconset")
    try files.createDirectory(at: iconSet, withIntermediateDirectories: true)
    for (name, pixels) in [("small.png", 40), ("large.png", 1024), ("dark.png", 1024)] {
        try Data(base64Encoded: shelfIconFixture(pixels: pixels, noisy: false))!.write(to: iconSet.appendingPathComponent(name))
    }
    try Data("""
    {"images": [
        {"filename": "small.png", "idiom": "universal", "platform": "ios", "scale": "2x", "size": "20x20"},
        {"appearances": [{"appearance": "luminosity", "value": "dark"}], "filename": "dark.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"},
        {"filename": "large.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}
    ]}
    """.utf8).write(to: iconSet.appendingPathComponent("Contents.json"))
    let iconProject = Project(name: "IconApp", bundleIdentifier: "com.lucaswkuipers.IconApp", delivery: .shelf, xcodeProject: nil, scheme: nil, prepareScript: nil)
    let shelfIconData = Data(base64Encoded: try shelfIcon(root: iconRoot, metadata: iconProject)!)!
    let shelfIconProperties = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithData(shelfIconData as CFData, nil)!, 0, nil) as! [CFString: Any]
    try expect(shelfIconProperties[kCGImagePropertyPixelWidth] as? Int == 256, "Shelf icons come from the largest light icon at 256 pixels, sharp at 80 points on 3x screens")

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
