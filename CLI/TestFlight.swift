import CryptoKit
import Foundation

struct TestFlightConfiguration: Codable {
    static let personalTeam = "AR7T5G5Z83"
    static let bundlePrefix = "com.lucaswkuipers."
    static let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/uikit-app")

    let keyID: String
    let issuer: String
    let keyPath: String
    let testerEmail: String
    let accountBundle: String

    static func load() throws -> Self {
        let path = directory.appendingPathComponent("testflight.json")
        guard files.fileExists(atPath: path.path) else {
            throw RequiredAction(result: "needs-testflight-setup", message: "Personal TestFlight credentials have not been configured.", command: "uikit-app setup-testflight --help")
        }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: path))
    }

    func validate() throws {
        guard UUID(uuidString: issuer) != nil, keyID.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil,
              testerEmail.contains("@"), !testerEmail.lowercased().hasSuffix("@amo.co"),
              accountBundle.hasPrefix(Self.bundlePrefix) else {
            throw CommandError(message: "TestFlight requires valid personal-account credentials and an existing personal bundle identifier.")
        }
    }
}

struct AppleResource: Decodable {
    let id: String
    let type: String
    let attributes: [String: JSONValue]?

    func string(_ key: String) -> String? { attributes?[key]?.string }
    func bool(_ key: String) -> Bool? { attributes?[key]?.bool }
}

enum JSONValue: Decodable {
    case string(String)
    case bool(Bool)
    case other

    var string: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    var bool: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else { self = .other }
    }
}

struct AppleList: Decodable {
    struct Links: Decodable { let next: String? }
    let data: [AppleResource]
    let links: Links?
}

struct AppleItem: Decodable { let data: AppleResource }

struct AppStoreClient {
    let configuration: TestFlightConfiguration
    let key: P256.Signing.PrivateKey

    init(configuration: TestFlightConfiguration) throws {
        try configuration.validate()
        self.configuration = configuration
        key = try P256.Signing.PrivateKey(pemRepresentation: String(contentsOfFile: configuration.keyPath, encoding: .utf8))
    }

    func token() throws -> String {
        func encode(_ data: Data) -> String {
            data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        let issued = Int(Date().timeIntervalSince1970)
        let header = try JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": configuration.keyID, "typ": "JWT"])
        let payload = try JSONSerialization.data(withJSONObject: ["iss": configuration.issuer, "iat": issued, "exp": issued + 600, "aud": "appstoreconnect-v1"])
        let message = encode(header) + "." + encode(payload)
        return message + "." + encode(try key.signature(for: Data(message.utf8)).rawRepresentation)
    }

    @discardableResult
    func request(_ method: String, path: String, query: [String: String], body: [String: Any]?) throws -> Data {
        var components = URLComponents(string: "https://api.appstoreconnect.apple.com\(path)")!
        components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.timeoutInterval = 45
        request.setValue("Bearer \(try token())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        return try appleRequest(request)
    }

    func list(_ path: String, query: [String: String]) throws -> [AppleResource] {
        let response = try request("GET", path: path, query: query.merging(["limit": "200"], uniquingKeysWith: { first, _ in first }), body: nil)
        let list = try JSONDecoder().decode(AppleList.self, from: response)
        guard list.links?.next == nil else {
            throw CommandError(message: "App Store Connect results exceed one page for \(path); narrow the query before proceeding.")
        }
        return list.data
    }

    func item(_ path: String) throws -> AppleResource {
        try JSONDecoder().decode(AppleItem.self, from: request("GET", path: path, query: [:], body: nil)).data
    }

    func create(type: String, attributes: [String: Any], relationships: [String: Any]) throws -> AppleResource {
        let data: [String: Any] = ["type": type, "attributes": attributes, "relationships": relationships]
        return try JSONDecoder().decode(AppleItem.self, from: request("POST", path: "/v1/\(type)", query: [:], body: ["data": data])).data
    }

    func verifyPersonalAccount() throws {
        let bundles = try list("/v1/bundleIds", query: ["filter[identifier]": configuration.accountBundle])
        guard bundles.count == 1, bundles[0].string("seedId") == TestFlightConfiguration.personalTeam else {
            throw CommandError(message: "Personal account check failed. This API key cannot verify \(configuration.accountBundle) under team \(TestFlightConfiguration.personalTeam). No changes made.")
        }
        let users = try list("/v1/users", query: ["filter[username]": configuration.testerEmail, "filter[roles]": "ACCOUNT_HOLDER"])
        guard users.count == 1 else {
            throw CommandError(message: "The configured tester is not this App Store Connect account's Account Holder. No changes made.")
        }
    }
}

func setupTestFlight(options: Options) throws {
    guard let keyPath = options.values["--key"], let keyID = options.values["--key-id"], let issuer = options.values["--issuer"],
          let email = options.values["--tester"], let bundle = options.values["--account-bundle"] else {
        throw CommandError(message: "Required: --key <file.p8> --key-id <ID> --issuer <UUID> --tester <personal-email> --account-bundle <existing-personal-bundle-ID>")
    }
    let input = TestFlightConfiguration(keyID: keyID, issuer: issuer, keyPath: URL(fileURLWithPath: keyPath).path, testerEmail: email, accountBundle: bundle)
    let client = try AppStoreClient(configuration: input)
    try client.verifyPersonalAccount()
    let directory = TestFlightConfiguration.directory
    try files.createDirectory(at: directory, withIntermediateDirectories: true)
    let storedKey = directory.appendingPathComponent("AuthKey_\(keyID).p8")
    if URL(fileURLWithPath: input.keyPath).standardizedFileURL != storedKey.standardizedFileURL {
        try Data(contentsOf: URL(fileURLWithPath: input.keyPath)).write(to: storedKey, options: .atomic)
    }
    try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storedKey.path)
    let saved = TestFlightConfiguration(keyID: keyID, issuer: issuer, keyPath: storedKey.path, testerEmail: email, accountBundle: bundle)
    let configurationPath = directory.appendingPathComponent("testflight.json")
    try JSONEncoder().encode(saved).write(to: configurationPath, options: .atomic)
    try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configurationPath.path)
    try emit(["result": "personal-testflight-configured", "team": TestFlightConfiguration.personalTeam, "tester": email])
}

struct DeliveryState: Codable {
    var fingerprint: String
    let appID: String
    let bundleIdentifier: String
    let buildNumber: String
    let archivePath: String
    var phase: String

    func save(_ url: URL) throws { try JSONEncoder().encode(self).write(to: url, options: .atomic) }
}

func sourceFingerprint(_ root: URL) throws -> String {
    var enumerationError: Error?
    guard let enumerator = files.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [], errorHandler: { _, error in
        enumerationError = error
        return false
    }) else {
        throw CommandError(message: "Cannot enumerate project sources.")
    }
    var paths: [URL] = []
    for case let url as URL in enumerator {
        if [".git", ".build", ".DS_Store", "xcuserdata", "build", "DerivedData"].contains(url.lastPathComponent) { enumerator.skipDescendants(); continue }
        if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true { paths.append(url) }
    }
    if let enumerationError { throw enumerationError }
    guard !paths.isEmpty else { throw CommandError(message: "Project contains no readable source files. Delivery stopped.") }
    var hash = SHA256()
    for url in paths.sorted(by: { $0.path < $1.path }) {
        hash.update(data: Data(url.path.dropFirst(root.path.count).utf8))
        hash.update(data: try Data(contentsOf: url))
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}

func verifyPersonalSettings(_ settings: [String: Any], expectedBundle: String) throws {
    guard expectedBundle.hasPrefix(TestFlightConfiguration.bundlePrefix),
          settings["PRODUCT_BUNDLE_IDENTIFIER"] as? String == expectedBundle,
          settings["DEVELOPMENT_TEAM"] as? String == TestFlightConfiguration.personalTeam,
          settings["CODE_SIGN_STYLE"] as? String == "Automatic" else {
        throw CommandError(message: "TestFlight is restricted to personal team \(TestFlightConfiguration.personalTeam), personal bundle identifiers, and automatic signing.")
    }
}

func personalGroup(client: AppStoreClient, appID: String, web: () throws -> AppleWebSession) throws -> AppleResource {
    let email = client.configuration.testerEmail.lowercased()
    let groups = try client.list("/v1/betaGroups", query: ["filter[app]": appID, "filter[isInternalGroup]": "true"])
    for group in groups where group.bool("hasAccessToAllBuilds") == true || group.string("name") == "Personal" {
        let testers = try client.list("/v1/betaGroups/\(group.id)/betaTesters", query: [:])
        guard testers.allSatisfy({ $0.string("email")?.lowercased() == email }) else {
            throw CommandError(message: "Group \(group.string("name") ?? group.id) can receive this build and contains other testers. Delivery stopped before upload.")
        }
    }
    let group: AppleResource
    if let existing = groups.first(where: { $0.string("name") == "Personal" }) { group = existing }
    else {
        group = try client.create(type: "betaGroups", attributes: ["name": "Personal", "isInternalGroup": true, "hasAccessToAllBuilds": false, "publicLinkEnabled": false], relationships: ["app": ["data": ["type": "apps", "id": appID]]])
    }
    guard group.bool("isInternalGroup") == true else { throw CommandError(message: "Expected an internal tester group.") }
    let members = try client.list("/v1/betaGroups/\(group.id)/betaTesters", query: [:])
    if !members.contains(where: { $0.string("email")?.lowercased() == email }) {
        let testers = try client.list("/v1/betaTesters", query: ["filter[email]": client.configuration.testerEmail, "filter[apps]": appID])
        if let tester = testers.first {
            try client.request("POST", path: "/v1/betaGroups/\(group.id)/relationships/betaTesters", query: [:], body: ["data": [["type": "betaTesters", "id": tester.id]]])
        } else {
            status("Adding the personal Account Holder to internal testing…")
            let session = try web()
            do { try session.addInternalTester(groupID: group.id) }
            catch {
                let reconciled = try client.list("/v1/betaGroups/\(group.id)/betaTesters", query: [:])
                guard reconciled.contains(where: { $0.string("email")?.lowercased() == email }) else { throw error }
            }
        }
    }
    let verified = try client.list("/v1/betaGroups/\(group.id)/betaTesters", query: [:])
    guard verified.count == 1, verified[0].string("email")?.lowercased() == email else {
        throw CommandError(message: "The Personal internal group must contain only the configured tester.")
    }
    return group
}

func deliverTestFlight(directory: String, options: Options) throws {
    guard let seconds = Int(options.values["--wait-seconds"] ?? "1800"), (0...3600).contains(seconds) else {
        throw CommandError(message: "--wait-seconds must be between 0 and 3600.")
    }
    let configuration = try TestFlightConfiguration.load()
    let client = try AppStoreClient(configuration: configuration)
    try client.verifyPersonalAccount()
    let root = URL(fileURLWithPath: directory).standardizedFileURL.resolvingSymlinksInPath()
    let metadata = try JSONDecoder().decode(Project.self, from: Data(contentsOf: root.appendingPathComponent(".uikit-app.json")))
    try validate(metadata.name, pattern: "^[A-Za-z][A-Za-z0-9]*$", label: "project name")
    try validate(metadata.bundleIdentifier, pattern: "^[A-Za-z0-9-]+(?:\\.[A-Za-z0-9-]+)+$", label: "bundle identifier")
    let lockDirectory = TestFlightConfiguration.directory.appendingPathComponent("locks")
    try files.createDirectory(at: lockDirectory, withIntermediateDirectories: true)
    let lockURL = lockDirectory.appendingPathComponent("\(metadata.bundleIdentifier).lock")
    let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { throw CommandError(message: "Cannot open delivery lock.") }
    defer { close(descriptor) }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
        throw CommandError(message: "Another delivery is already running for this app.")
    }
    let directoryDigest = SHA256.hash(data: Data(root.path.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    let cache = files.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/uikit-app/\(metadata.name)-\(directoryDigest)")
    try files.createDirectory(at: cache, withIntermediateDirectories: true)
    let projectArguments = ["-project", root.appendingPathComponent("\(metadata.name).xcodeproj").path, "-scheme", metadata.name, "-configuration", "Release"]
    let settingsJSON = try run("/usr/bin/xcodebuild", projectArguments + ["-destination", "generic/platform=iOS", "-showBuildSettings", "-json"], log: nil, separateError: true)
    guard let targets = try JSONSerialization.jsonObject(with: Data(settingsJSON.utf8)) as? [[String: Any]],
          let target = targets.first(where: { $0["target"] as? String == metadata.name }), let settings = target["buildSettings"] as? [String: Any] else {
        throw CommandError(message: "Cannot read application build settings.")
    }
    try verifyPersonalSettings(settings, expectedBundle: metadata.bundleIdentifier)
    for target in targets {
        if let values = target["buildSettings"] as? [String: Any], let team = values["DEVELOPMENT_TEAM"] as? String, !team.isEmpty, team != TestFlightConfiguration.personalTeam {
            throw CommandError(message: "A target uses a different development team. Delivery stopped.")
        }
    }
    let bundles = try client.list("/v1/bundleIds", query: ["filter[identifier]": metadata.bundleIdentifier])
    if bundles.isEmpty {
        _ = try client.create(type: "bundleIds", attributes: ["identifier": metadata.bundleIdentifier, "name": metadata.name, "platform": "IOS"], relationships: [:])
    } else if bundles[0].string("seedId") != TestFlightConfiguration.personalTeam {
        throw CommandError(message: "Bundle ID belongs to a different team.")
    }
    var webSession: AppleWebSession?
    func web() throws -> AppleWebSession {
        if let webSession { return webSession }
        let session = try AppleWebSession(configuration: configuration)
        webSession = session
        return session
    }
    let app = try registeredApp(metadata: metadata, version: settings["MARKETING_VERSION"] as? String ?? "1.0", client: client, web: web)
    let group = try personalGroup(client: client, appID: app.id, web: web)
    let fingerprint = try sourceFingerprint(root)
    let stateURL = cache.appendingPathComponent("testflight-state.json")
    var state: DeliveryState
    if files.fileExists(atPath: stateURL.path) {
        let saved = try JSONDecoder().decode(DeliveryState.self, from: Data(contentsOf: stateURL))
        guard saved.appID == app.id, saved.bundleIdentifier == metadata.bundleIdentifier else {
            throw CommandError(message: "Saved delivery belongs to a different app.")
        }
        if saved.fingerprint == fingerprint || !["delivered", "rejected"].contains(saved.phase) { state = saved }
        else { state = try newDelivery(fingerprint: fingerprint, appID: app.id, bundle: metadata.bundleIdentifier, cache: cache, client: client) }
    } else { state = try newDelivery(fingerprint: fingerprint, appID: app.id, bundle: metadata.bundleIdentifier, cache: cache, client: client) }
    try state.save(stateURL)
    let archive = URL(fileURLWithPath: state.archivePath)
    let authentication = ["-allowProvisioningUpdates", "-authenticationKeyPath", configuration.keyPath, "-authenticationKeyID", configuration.keyID, "-authenticationKeyIssuerID", configuration.issuer]
    if state.fingerprint != fingerprint && ["created", "archived"].contains(state.phase) {
        state.fingerprint = fingerprint
        state.phase = "created"
        try state.save(stateURL)
    }
    if state.phase == "created" {
        if files.fileExists(atPath: archive.path) { try files.removeItem(at: archive) }
        status("Archiving build \(state.buildNumber) for personal TestFlight…")
        try run("/usr/bin/xcodebuild", projectArguments + ["-destination", "generic/platform=iOS", "-derivedDataPath", cache.appendingPathComponent("DerivedData").path, "-archivePath", archive.path, "-quiet", "archive", "CURRENT_PROJECT_VERSION=\(state.buildNumber)", "DEVELOPMENT_TEAM=\(TestFlightConfiguration.personalTeam)"] + authentication, log: cache.appendingPathComponent("testflight-archive.log"))
        guard try sourceFingerprint(root) == fingerprint else {
            throw RequiredAction(result: "sources-changed-during-build", message: "Sources changed while archiving. Rerun after edits finish; this archive was not uploaded.", command: "uikit-app testflight \(root.path)")
        }
        state.phase = "archived"
        try state.save(stateURL)
    }
    if state.phase == "upload-started", options.retryUpload {
        let existing = try client.list("/v1/builds", query: ["filter[app]": app.id, "filter[version]": state.buildNumber])
        state.phase = existing.isEmpty ? "archived" : "uploaded"
        try state.save(stateURL)
    }
    if state.phase == "archived" {
        try verifyArchive(archive: archive, metadata: metadata, buildNumber: state.buildNumber)
        let exportOptions: [String: Any] = ["method": "app-store-connect", "destination": "upload", "signingStyle": "automatic", "teamID": TestFlightConfiguration.personalTeam, "testFlightInternalTestingOnly": true, "manageAppVersionAndBuildNumber": false, "uploadSymbols": true]
        let optionsURL = cache.appendingPathComponent("TestFlightExportOptions.plist")
        try PropertyListSerialization.data(fromPropertyList: exportOptions, format: .xml, options: 0).write(to: optionsURL, options: .atomic)
        status("Uploading internal-only build \(state.buildNumber)…")
        state.phase = "upload-started"
        try state.save(stateURL)
        try run("/usr/bin/xcodebuild", ["-exportArchive", "-archivePath", archive.path, "-exportOptionsPlist", optionsURL.path, "-exportPath", cache.appendingPathComponent("TestFlightExport").path, "-allowProvisioningUpdates"], log: cache.appendingPathComponent("testflight-upload.log"))
        state.phase = "uploaded"
        try state.save(stateURL)
    }
    let deadline = Date().addingTimeInterval(Double(seconds))
    var previousStatus = ""
    while true {
        let builds = try client.list("/v1/builds", query: ["filter[app]": app.id, "filter[version]": state.buildNumber])
        if let build = builds.first {
            let processing = build.string("processingState") ?? "UNKNOWN"
            if processing == "FAILED" || processing == "INVALID" {
                state.phase = "rejected"
                try state.save(stateURL)
                throw CommandError(message: "Apple rejected build \(state.buildNumber): \(processing). Inspect App Store Connect and \(cache.path).")
            }
            if processing == "VALID" {
                guard build.string("buildAudienceType") == "INTERNAL_ONLY" else {
                    throw CommandError(message: "Uploaded build is not marked INTERNAL_ONLY. Distribution stopped.")
                }
                let detail = try client.item("/v1/builds/\(build.id)/buildBetaDetail")
                let internalState = detail.string("internalBuildState") ?? "UNKNOWN"
                if ["MISSING_EXPORT_COMPLIANCE", "IN_EXPORT_COMPLIANCE_REVIEW", "PROCESSING_EXCEPTION", "EXPIRED"].contains(internalState) {
                    throw CommandError(message: "TestFlight requires attention: \(internalState). Open https://appstoreconnect.apple.com/apps/\(app.id)/testflight/ios")
                }
                if internalState == "READY_FOR_BETA_TESTING" || internalState == "IN_BETA_TESTING" {
                    let assigned = try client.list("/v1/builds", query: ["filter[app]": app.id, "filter[version]": state.buildNumber, "filter[betaGroups]": group.id])
                    if !assigned.contains(where: { $0.id == build.id }) {
                        try client.request("POST", path: "/v1/builds/\(build.id)/relationships/betaGroups", query: [:], body: ["data": [["type": "betaGroups", "id": group.id]]])
                    }
                    let verified = try client.list("/v1/builds", query: ["filter[app]": app.id, "filter[version]": state.buildNumber, "filter[betaGroups]": group.id])
                    guard verified.contains(where: { $0.id == build.id }) else { throw CommandError(message: "Build assignment was not confirmed.") }
                    state.phase = "delivered"
                    try state.save(stateURL)
                    try emit(["result": "available-to-internal-tester", "sourcesChanged": String(state.fingerprint != sourceFingerprint(root)), "app": metadata.name, "build": state.buildNumber, "team": TestFlightConfiguration.personalTeam, "tester": configuration.testerEmail, "testflight": "https://appstoreconnect.apple.com/teams/\(configuration.issuer)/apps/\(app.id)/testflight/groups/\(group.id)", "logs": cache.path])
                    return
                }
            }
            if previousStatus != processing { status("Apple build status: \(processing)"); previousStatus = processing }
        } else if previousStatus.isEmpty {
            status("Waiting for Apple to register the uploaded build…")
            previousStatus = "waiting"
        }
        if Date() >= deadline {
            try emit(["result": "processing", "build": state.buildNumber, "phase": state.phase, "logs": cache.path, "resume": "uikit-app testflight \(root.path)"])
            return
        }
        Thread.sleep(forTimeInterval: max(0, min(10, deadline.timeIntervalSinceNow)))
    }
}

func verifyArchive(archive: URL, metadata: Project, buildNumber: String) throws {
    let application = archive.appendingPathComponent("Products/Applications/\(metadata.name).app")
    try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", application.path], log: nil)
    let signature = try run("/usr/bin/codesign", ["-dvv", application.path], log: nil)
    guard signature.split(separator: "\n").contains("TeamIdentifier=\(TestFlightConfiguration.personalTeam)") else {
        throw CommandError(message: "Archive signature is not from the personal team.")
    }
    let information = try PropertyListSerialization.propertyList(from: Data(contentsOf: application.appendingPathComponent("Info.plist")), format: nil) as? [String: Any]
    guard information?["CFBundleIdentifier"] as? String == metadata.bundleIdentifier,
          information?["CFBundleVersion"] as? String == buildNumber,
          information?["ITSAppUsesNonExemptEncryption"] is Bool,
          files.fileExists(atPath: application.appendingPathComponent("embedded.mobileprovision").path) else {
        throw CommandError(message: "Archive identity/version mismatch, missing provisioning, or missing ITSAppUsesNonExemptEncryption. Declare the app's actual encryption use before uploading.")
    }
}

func nextBuildNumber(_ previous: String?) throws -> String {
    guard let previous else { return "1" }
    let parts = previous.split(separator: ".").compactMap { Int($0) }
    guard (1...3).contains(parts.count), parts.count == previous.split(separator: ".").count,
          parts[0] > 0, parts[0] <= 9999, parts.dropFirst().allSatisfy({ (0...99).contains($0) }) else {
        throw CommandError(message: "Unsupported previous build number: \(previous)")
    }
    if parts[0] < 9999 { return String(parts[0] + 1) }
    var next = parts + Array(repeating: 0, count: 3 - parts.count)
    guard next[1] < 99 || next[2] < 99 else { throw CommandError(message: "Build number range exhausted.") }
    if next[2] < 99 { next[2] += 1 }
    else { next[1] += 1; next[2] = 0 }
    return next.map(String.init).joined(separator: ".")
}

func newDelivery(fingerprint: String, appID: String, bundle: String, cache: URL, client: AppStoreClient) throws -> DeliveryState {
    let response = try client.request("GET", path: "/v1/builds", query: ["filter[app]": appID, "sort": "-uploadedDate", "limit": "1"], body: nil)
    let previous = try JSONDecoder().decode(AppleList.self, from: response).data.first?.string("version")
    let number = try nextBuildNumber(previous)
    return DeliveryState(fingerprint: fingerprint, appID: appID, bundleIdentifier: bundle, buildNumber: number, archivePath: cache.appendingPathComponent("TestFlight-\(number).xcarchive").path, phase: "created")
}
