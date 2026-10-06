import CryptoKit
import Foundation

struct AppleWebSession {
    let configuration: TestFlightConfiguration
    let session: URLSession

    static var executable: String {
        for path in ["/opt/homebrew/bin/asc", "/usr/local/bin/asc"] where files.isExecutableFile(atPath: path) { return path }
        return "/opt/homebrew/bin/asc"
    }

    static var environment: [String: String] {
        var values = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("ASC_") }
        values["ASC_TELEMETRY_DISABLED"] = "1"
        return values
    }

    init(configuration: TestFlightConfiguration) throws {
        self.configuration = configuration
        guard files.isExecutableFile(atPath: Self.executable) else {
            throw RequiredAction(result: "needs-asc", message: "Install the CLI used for Apple sign-in.", command: "brew install asc")
        }
        let directory = TestFlightConfiguration.directory.appendingPathComponent("session-\(UUID().uuidString)")
        try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: directory) }
        let exported = directory.appendingPathComponent("session.json")
        do {
            try run(Self.executable, ["web", "auth", "login", "--apple-id", configuration.testerEmail, "--public-provider-id", configuration.issuer], log: nil, environment: Self.environment, separateError: true)
            try run(Self.executable, ["web", "auth", "export", "--apple-id", configuration.testerEmail, "--output-path", exported.path], log: nil, environment: Self.environment, separateError: true)
        } catch {
            throw Self.loginRequired
        }
        let bundle = try JSONDecoder().decode(SessionBundle.self, from: Data(contentsOf: exported))
        guard bundle.kind == "asc-web-session", bundle.version == 1,
              bundle.appleId.lowercased() == configuration.testerEmail.lowercased() else {
            throw CommandError(message: "Apple CLI session is not the configured personal account.")
        }
        let options = URLSessionConfiguration.ephemeral
        options.timeoutIntervalForRequest = 45
        options.timeoutIntervalForResource = 90
        options.httpCookieAcceptPolicy = .always
        for cookie in bundle.cookies where URL(string: cookie.url)?.host == "appstoreconnect.apple.com" {
            var properties: [HTTPCookiePropertyKey: Any] = [.name: cookie.name, .value: cookie.value, .domain: "appstoreconnect.apple.com", .path: cookie.path ?? "/", .secure: "TRUE"]
            if let expires = cookie.expires.flatMap({ ISO8601DateFormatter().date(from: $0) }) { properties[.expires] = expires }
            if let value = HTTPCookie(properties: properties) { options.httpCookieStorage?.setCookie(value) }
        }
        session = URLSession(configuration: options)
        try verifyProvider()
    }

    static var loginRequired: RequiredAction {
        RequiredAction(result: "needs-apple-login", message: "Apple CLI sign-in is required. Enter the personal password and 2FA in Terminal; never in chat.", command: "uikit-app login")
    }

    func request(_ method: String, path: String, body: [String: Any]? = nil) throws -> Data {
        var request = URLRequest(url: URL(string: "https://appstoreconnect.apple.com\(path)")!)
        request.httpMethod = method
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("[asc-ui]", forHTTPHeaderField: "x-csrf-itc")
        request.setValue("olympus-ui", forHTTPHeaderField: "X-Requested-With")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        do { return try appleRequest(request, session: session) }
        catch let error as AppleHTTPError where error.status == 401 || (path == "/olympus/v1/session" && error.status == 403) { throw Self.loginRequired }
    }

    func verifyProvider() throws {
        let data = try request("GET", path: "/olympus/v1/session")
        let info = try JSONDecoder().decode(ProviderSession.self, from: data)
        try info.verify(configuration: configuration)
    }

    func createApp(metadata: Project, version: String, name: String? = nil) throws -> AppleResource {
        let body = appRegistrationBody(name: name ?? metadata.name, bundle: metadata.bundleIdentifier, version: version)
        return try JSONDecoder().decode(AppleItem.self, from: request("POST", path: "/iris/v1/apps", body: body)).data
    }

    func limitAccess(appID: String) throws {
        _ = try request("POST", path: "/iris/v1/userAppPermissions", body: ["data": ["type": "userAppPermissions", "attributes": ["appAdamId": appID, "operationType": "REVOKE", "userOperationType": "ALL_SILOABLE_USERS"]]])
    }

    func addInternalTester(groupID: String) throws {
        _ = try request("POST", path: "/iris/v1/bulkBetaTesterAssignments", body: ["data": ["type": "bulkBetaTesterAssignments", "attributes": ["betaTesters": [["email": configuration.testerEmail, "errors": []] as [String: Any]]], "relationships": ["betaGroup": ["data": ["type": "betaGroups", "id": groupID]]]]])
    }
}

func registeredApp(metadata: Project, version: String, client: AppStoreClient, web: () throws -> AppleWebSession) throws -> AppleResource {
    let query = ["filter[bundleId]": metadata.bundleIdentifier]
    let marker = TestFlightConfiguration.directory.appendingPathComponent("locks/\(metadata.bundleIdentifier).registration")
    var app = try client.list("/v1/apps", query: query).first
    if app == nil {
        let session = try web()
        try Data(metadata.bundleIdentifier.utf8).write(to: marker, options: .atomic)
        status("Registering the personal app in App Store Connect…")
        do { app = try session.createApp(metadata: metadata, version: version) }
        catch {
            app = try client.list("/v1/apps", query: query).first
            if app == nil {
                if let failure = error as? AppleHTTPError, failure.status == 409,
                   failure.message.lowercased().contains("name"),
                   failure.message.lowercased().contains("already") || failure.message.contains("DUPLICATE") {
                    let suffix = SHA256.hash(data: Data(metadata.bundleIdentifier.utf8)).prefix(3).map { String(format: "%02x", $0) }.joined()
                    app = try session.createApp(metadata: metadata, version: version, name: "\(metadata.name.prefix(23)) \(suffix)")
                } else { throw error }
            }
        }
    }
    guard let app, app.string("bundleId") == metadata.bundleIdentifier else {
        throw CommandError(message: "App registration did not return the expected personal bundle identifier.")
    }
    if files.fileExists(atPath: marker.path) {
        try web().limitAccess(appID: app.id)
        try files.removeItem(at: marker)
    }
    let verified = try client.item("/v1/apps/\(app.id)")
    guard verified.string("bundleId") == metadata.bundleIdentifier else { throw CommandError(message: "Registered app identity could not be verified.") }
    return verified
}

private struct SessionBundle: Decodable {
    struct Cookie: Decodable {
        let url: String
        let name: String
        let value: String
        let path: String?
        let expires: String?
    }
    let kind: String
    let version: Int
    let appleId: String
    let cookies: [Cookie]
}

struct ProviderSession: Decodable {
    struct Provider: Decodable { let publicProviderId: String }
    struct User: Decodable { let emailAddress: String }
    let provider: Provider
    let user: User

    func verify(configuration: TestFlightConfiguration) throws {
        guard user.emailAddress.lowercased() == configuration.testerEmail.lowercased(),
              provider.publicProviderId.lowercased() == configuration.issuer.lowercased() else {
            throw RequiredAction(result: "wrong-apple-provider", message: "Apple CLI session does not select the verified personal App Store Connect provider. No app registration performed.", command: "uikit-app login")
        }
    }
}

func appRegistrationBody(name: String, bundle: String, version: String) -> [String: Any] {
    func relationship(_ type: String, _ id: String) -> [String: Any] { ["data": [["type": type, "id": id]]] }
    return ["data": ["type": "apps", "attributes": ["sku": bundle, "bundleId": bundle, "primaryLocale": "en-US"], "relationships": ["appStoreVersions": relationship("appStoreVersions", "${new-appStoreVersion}"), "appInfos": relationship("appInfos", "${new-appInfo}")]],
            "included": [
                ["type": "appStoreVersions", "id": "${new-appStoreVersion}", "attributes": ["versionString": version, "platform": "IOS"], "relationships": ["appStoreVersionLocalizations": relationship("appStoreVersionLocalizations", "${new-appStoreVersionLocalization}")]],
                ["type": "appStoreVersionLocalizations", "id": "${new-appStoreVersionLocalization}", "attributes": ["locale": "en-US"]],
                ["type": "appInfos", "id": "${new-appInfo}", "relationships": ["appInfoLocalizations": relationship("appInfoLocalizations", "${new-appInfoLocalization}")]],
                ["type": "appInfoLocalizations", "id": "${new-appInfoLocalization}", "attributes": ["locale": "en-US", "name": String(name.prefix(30))]]
            ]]
}

func login() throws {
    let configuration = try TestFlightConfiguration.load()
    try AppStoreClient(configuration: configuration).verifyPersonalAccount()
    try runInteractive(AppleWebSession.executable, arguments: ["web", "auth", "login", "--apple-id", configuration.testerEmail, "--public-provider-id", configuration.issuer], environment: AppleWebSession.environment)
    _ = try AppleWebSession(configuration: configuration)
    try emit(["result": "personal-apple-login-ready", "team": TestFlightConfiguration.personalTeam])
}
