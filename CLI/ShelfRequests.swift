import Foundation

struct ShelfRequestsConfiguration: Codable {
    static let path = TestFlightConfiguration.directory.appendingPathComponent("shelf-requests.json")

    let url: String
    let adminToken: String

    static func load() throws -> Self? {
        guard files.fileExists(atPath: path.path) else {
            return nil
        }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: path))
    }
}

struct ShelfWorkerRequest: Decodable {
    let id: String
    let udid: String
    let deviceName: String
    let model: String
    let systemVersion: String
    let status: String
}

struct ShelfAccessRecord {
    let name: String
    let changeTag: String
    let udid: String
    let deviceName: String
    let status: String

    init(_ record: [String: Any]) throws {
        let fields = record["fields"] as? [String: Any] ?? [:]
        func value(_ key: String) -> String? {
            (fields[key] as? [String: Any])?["value"] as? String
        }
        guard let name = record["recordName"] as? String, let changeTag = record["recordChangeTag"] as? String,
              let udid = value("udid"), let deviceName = value("deviceName"), let status = value("status") else {
            throw CommandError(message: "CloudKit returned an incomplete access request: \(record["recordName"] ?? "unnamed").")
        }
        self.name = name
        self.changeTag = changeTag
        self.udid = udid
        self.deviceName = deviceName
        self.status = status
    }
}

struct ShelfRequests {
    let configuration: ShelfRequestsConfiguration
    let cloud: ShelfNotificationPublisher
    let session: URLSession

    static func load(session: URLSession) throws -> Self? {
        guard let configuration = try ShelfRequestsConfiguration.load() else {
            return nil
        }
        guard let notifications = try ShelfNotificationConfiguration.load() else {
            throw CommandError(message: "Access requests reach the shelf owner through CloudKit; configure shelf notifications first.")
        }
        return Self(configuration: configuration, cloud: try ShelfNotificationPublisher(configuration: notifications, session: session), session: session)
    }

    func workerRequest(_ path: String, body: [String: Any]?) throws -> Data {
        var request = URLRequest(url: URL(string: "\(configuration.url)\(path)")!)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.timeoutInterval = 20
        request.setValue("Bearer \(configuration.adminToken)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return try appleRequest(request, session: session)
    }

    func updateWorker(_ id: String, status: String) throws {
        _ = try workerRequest("/admin/requests/\(id)", body: ["status": status])
    }

    func records() throws -> [ShelfAccessRecord] {
        let results = try cloud.records(operation: "query", body: ["query": ["recordType": "ShelfAccessRequest"], "resultsLimit": 200])
        if let failure = results.first(where: { $0["serverErrorCode"] != nil }) {
            throw CommandError(message: "CloudKit could not list access requests: \(failure["serverErrorCode"] ?? "unknown error").")
        }
        return try results.map(ShelfAccessRecord.init)
    }

    func modify(_ operation: [String: Any]) throws {
        let results = try cloud.records(operation: "modify", body: ["operations": [operation]])
        guard results.count == 1, results[0]["serverErrorCode"] == nil else {
            throw CommandError(message: "CloudKit did not save the access request: \(results.first?["serverErrorCode"] ?? "no result").")
        }
    }

    func setStatus(_ status: String, of record: ShelfAccessRecord) throws {
        try modify(["operationType": "update", "record": ["recordType": "ShelfAccessRequest", "recordName": record.name, "recordChangeTag": record.changeTag, "fields": ["status": ["value": status]]]])
    }

    func delete(_ record: ShelfAccessRecord) throws {
        try modify(["operationType": "forceDelete", "record": ["recordName": record.name]])
    }

    func relay(devices: ShelfDevices) throws {
        let pending = try JSONDecoder().decode([ShelfWorkerRequest].self, from: workerRequest("/admin/requests", body: nil)).filter { $0.status == "pending" }
        guard !pending.isEmpty else {
            return
        }
        let known = Set(try records().map(\.name))
        for request in pending {
            if devices.includes(request.udid) {
                try updateWorker(request.id, status: "ready")
                continue
            }
            if !known.contains(request.id) {
                let fields = ["deviceName": request.deviceName, "model": request.model, "systemVersion": request.systemVersion, "udid": request.udid, "status": "waiting"]
                try modify(["operationType": "create", "record": ["recordType": "ShelfAccessRequest", "recordName": request.id, "fields": fields.mapValues { ["value": $0] }]])
            }
            try updateWorker(request.id, status: "waiting")
            status("Asked the shelf owner to approve \(request.deviceName).")
        }
    }

    func markReady(devices: ShelfDevices) throws {
        for record in try records() where record.status == "preparing" && devices.includes(record.udid) {
            try setStatus("ready", of: record)
            try updateWorker(record.name, status: "ready")
        }
    }

    func finish(devices: ShelfDevices, complete: Bool) throws {
        for record in try records() {
            if ["preparing", "ready"].contains(record.status), devices.includes(record.udid) {
                try setStatus(complete ? "shared" : "failed", of: record)
                try updateWorker(record.name, status: "ready")
            } else if record.status == "removing", !devices.includes(record.udid) {
                try updateWorker(record.name, status: "removed")
                try delete(record)
            }
        }
    }

    func fail(devices: ShelfDevices) throws {
        for record in try records() {
            if ["preparing", "ready"].contains(record.status), devices.includes(record.udid) {
                try setStatus("failed", of: record)
            } else if record.status == "removing" {
                try setStatus("remove-failed", of: record)
            }
        }
    }
}

func processShelfRequests() {
    do {
        let session = URLSession(configuration: .ephemeral, delegate: RejectRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        guard let requests = try ShelfRequests.load(session: session) else {
            return
        }
        try requests.relay(devices: try ShelfDevices.load())
        let records = try requests.records()
        for record in records where record.status == "declined" {
            try requests.updateWorker(record.name, status: "declined")
            try requests.delete(record)
        }
        guard try shelfShareIsIdle() else {
            return
        }
        var work = false
        for record in records where record.status == "approved" {
            do {
                try addShelfDevice(udid: record.udid, name: record.deviceName)
                try requests.setStatus("preparing", of: record)
                try requests.updateWorker(record.name, status: "preparing")
                work = true
            } catch {
                status("Could not approve \(record.deviceName): \(error.localizedDescription)")
                try requests.setStatus("failed", of: record)
            }
        }
        let sharing = try ShelfSharing.load()
        for record in records where ["remove", "removing"].contains(record.status) {
            if sharing.devices.contains(where: { $0.udid.caseInsensitiveCompare(record.udid) == .orderedSame }) {
                try removeShelfDevice(record.udid)
            }
            if record.status == "remove" {
                try requests.setStatus("removing", of: record)
            }
            work = true
        }
        let devices = try ShelfDevices.load()
        for record in records where ["preparing", "ready"].contains(record.status) {
            if devices.includes(record.udid) {
                work = true
            } else {
                try requests.setStatus("failed", of: record)
            }
        }
        if work {
            try spawnShelfShare()
        }
    } catch {
        status("Shelf access requests deferred until a later refresh: \(error.localizedDescription)")
    }
}

func lockShelfShare() throws -> Int32 {
    let descriptor = open(TestFlightConfiguration.directory.appendingPathComponent("shelf-share.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else {
        throw CommandError(message: "Cannot open the shelf sharing lock.")
    }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
        close(descriptor)
        throw CommandError(message: "Another share-shelf run is still re-signing the shelf. Follow ~/Library/Logs/uikit-app/shelf-share.log instead of starting another.")
    }
    return descriptor
}

func shelfShareIsIdle() throws -> Bool {
    let descriptor = open(TestFlightConfiguration.directory.appendingPathComponent("shelf-share.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else {
        throw CommandError(message: "Cannot open the shelf sharing lock.")
    }
    defer { close(descriptor) }
    return flock(descriptor, LOCK_EX | LOCK_NB) == 0
}

func spawnShelfShare() throws {
    guard let executable = Bundle.main.executablePath else {
        throw CommandError(message: "Cannot locate the uikit-app executable.")
    }
    let logs = files.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/uikit-app")
    try files.createDirectory(at: logs, withIntermediateDirectories: true)
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, logs.appendingPathComponent("shelf-share.log").path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    posix_spawn_file_actions_adddup2(&actions, STDOUT_FILENO, STDERR_FILENO)
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
    let argumentPointers = [executable, "share-shelf"].map { strdup($0) } + [nil]
    let environmentPointers = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer {
        argumentPointers.forEach { free($0) }
        environmentPointers.forEach { free($0) }
    }
    var processID = pid_t()
    let result = argumentPointers.withUnsafeBufferPointer { arguments in
        environmentPointers.withUnsafeBufferPointer { environment in
            posix_spawn(&processID, executable, &actions, &attributes, arguments.baseAddress!, environment.baseAddress!)
        }
    }
    guard result == 0 else {
        throw CommandError(message: "Cannot start the shelf re-sign: \(String(cString: strerror(result)))")
    }
    status("Started re-signing the shelf in the background (process \(processID)); see ~/Library/Logs/uikit-app/shelf-share.log.")
}

@discardableResult
func wrangler(_ arguments: [String], directory: URL) throws -> String {
    var environment = ProcessInfo.processInfo.environment
    environment["npm_config_cache"] = files.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/uikit-app/npm").path
    environment["WRANGLER_SEND_METRICS"] = "false"
    environment["PATH"] = "/usr/local/bin:/opt/homebrew/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
    return try run("/usr/bin/env", ["-C", directory.path, "npx", "--yes", "wrangler@4.143.0"] + arguments, log: nil, environment: environment, separateError: true)
}

func writeShelfRequestProfile(url: String, to destination: URL) throws {
    let work = files.temporaryDirectory.appendingPathComponent("shelf-profile-\(UUID().uuidString)")
    try files.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? files.removeItem(at: work) }
    let profile: [String: Any] = [
        "PayloadContent": ["URL": "\(url)/enroll", "DeviceAttributes": ["UDID", "PRODUCT", "VERSION", "DEVICE_NAME"]],
        "PayloadOrganization": "Lucas Werner Kuipers",
        "PayloadDisplayName": "AppShelf access request",
        "PayloadDescription": "Sends this iPhone's device ID to Lucas so he can approve it for AppShelf. Nothing stays installed.",
        "PayloadIdentifier": "com.lucaswkuipers.AppShelf.request",
        "PayloadUUID": UUID().uuidString,
        "PayloadType": "Profile Service",
        "PayloadVersion": 1
    ]
    let unsigned = work.appendingPathComponent("unsigned.mobileconfig")
    try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0).write(to: unsigned)
    let signing = TestFlightConfiguration.directory.appendingPathComponent("direct-signing")
    let certificate = signing.appendingPathComponent("distribution.pem")
    func name(_ option: String, of path: URL) throws -> String {
        let output = try run("/usr/bin/openssl", ["x509", "-in", path.path, "-noout", option, "-nameopt", "RFC2253"], log: nil)
        return String(output.drop(while: { $0 != "=" }).dropFirst()).trimmingCharacters(in: .whitespaces)
    }
    let issuer = try name("-issuer", of: certificate)
    let candidates = try run("/usr/bin/security", ["find-certificate", "-a", "-c", "Apple Worldwide Developer Relations Certification Authority", "-p"], log: nil)
        .components(separatedBy: "-----END CERTIFICATE-----").filter { $0.contains("-----BEGIN CERTIFICATE-----") }
    var intermediate: URL?
    for (index, candidate) in candidates.enumerated() {
        let path = work.appendingPathComponent("intermediate-\(index).pem")
        try (candidate.trimmingCharacters(in: .whitespacesAndNewlines) + "\n-----END CERTIFICATE-----\n").write(to: path, atomically: true, encoding: .utf8)
        if try name("-subject", of: path) == issuer {
            intermediate = path
            break
        }
    }
    guard let intermediate else {
        throw CommandError(message: "Cannot find Apple's intermediate certificate for the distribution identity in the keychain.")
    }
    try run("/usr/bin/openssl", ["smime", "-sign", "-binary", "-nodetach", "-outform", "der", "-signer", certificate.path, "-inkey", signing.appendingPathComponent("distribution.key").path, "-certfile", intermediate.path, "-in", unsigned.path, "-out", destination.path], log: nil)
    guard try run("/usr/bin/security", ["cms", "-D", "-i", destination.path], log: nil, separateError: true).contains("\(url)/enroll") else {
        throw CommandError(message: "The signed access-request profile does not contain its enrollment URL.")
    }
}

func setupShelfRequests(template: URL) throws {
    guard let gist = try ShelfSharing.load().inviteGist else {
        throw RequiredAction(result: "needs-shelf-invite", message: "Create the AppShelf invite before access requests.", command: "uikit-app share-shelf")
    }
    guard try ShelfNotificationConfiguration.load() != nil else {
        throw CommandError(message: "Access requests reach the shelf owner through CloudKit; configure shelf notifications first.")
    }
    let directory = files.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/uikit-app/ShelfRequests")
    try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    for file in ["worker.js", "schema.sql"] {
        let destination = directory.appendingPathComponent(file)
        if files.fileExists(atPath: destination.path) {
            try files.removeItem(at: destination)
        }
        try files.copyItem(at: template.appendingPathComponent("CLI/ShelfRequests/\(file)"), to: destination)
    }
    guard !(try wrangler(["whoami"], directory: directory)).localizedCaseInsensitiveContains("not authenticated") else {
        throw RequiredAction(result: "needs-cloudflare-login", message: "Sign in to the free Cloudflare account in the browser, then rerun setup-shelf-requests.", command: "npx wrangler@4.143.0 login")
    }
    struct Database: Decodable {
        let uuid: String
        let name: String
    }
    func database() throws -> Database? {
        try JSONDecoder().decode([Database].self, from: Data(wrangler(["d1", "list", "--json"], directory: directory).utf8)).first { $0.name == "appshelf-requests" }
    }
    if try database() == nil {
        status("Creating the free Cloudflare D1 database for access requests…")
        try wrangler(["d1", "create", "appshelf-requests"], directory: directory)
    }
    guard let database = try database() else {
        throw CommandError(message: "Cloudflare did not list the appshelf-requests database after creating it.")
    }
    var components = URLComponents()
    components.scheme = "itms-services"
    components.host = ""
    components.queryItems = [URLQueryItem(name: "action", value: "download-manifest"), URLQueryItem(name: "url", value: "https://gist.githubusercontent.com/lucaswkuipers/\(gist)/raw/AppShelf.plist")]
    guard let installLink = components.url?.absoluteString else {
        throw CommandError(message: "Cannot create the AppShelf install link.")
    }
    let manifest = """
    name = "appshelf"
    main = "worker.js"
    compatibility_date = "2026-09-01"
    workers_dev = true
    preview_urls = false
    rules = [{ type = "Data", globs = ["**/*.mobileconfig"], fallthrough = false }]

    [vars]
    OWNER_NAME = "Lucas"
    INSTALL_LINK = "\(installLink)"

    [[d1_databases]]
    binding = "DB"
    database_name = "appshelf-requests"
    database_id = "\(database.uuid)"

    """
    try manifest.write(to: directory.appendingPathComponent("wrangler.toml"), atomically: true, encoding: .utf8)
    try wrangler(["d1", "execute", "appshelf-requests", "--remote", "--file", "schema.sql", "--yes"], directory: directory)
    let saved = try ShelfRequestsConfiguration.load()
    let profile = directory.appendingPathComponent("request.mobileconfig")
    func deploy() throws -> String {
        do {
            let output = try wrangler(["deploy"], directory: directory)
            guard let range = output.range(of: "https://appshelf\\.[A-Za-z0-9-]+\\.workers\\.dev", options: .regularExpression) else {
                throw CommandError(message: "Cloudflare deployed without reporting the appshelf workers.dev address:\n\(output)")
            }
            return String(output[range])
        } catch let error as CommandError where error.message.contains("workers.dev subdomain") {
            throw RequiredAction(result: "needs-workers-subdomain", message: "Choose your free workers.dev subdomain on the Cloudflare dashboard (Workers & Pages), then rerun setup-shelf-requests.", command: "open https://dash.cloudflare.com")
        }
    }
    var url = saved?.url
    if url == nil {
        try Data("pending".utf8).write(to: profile)
        url = try deploy()
    }
    guard let url else {
        throw CommandError(message: "Cannot determine the access-request address.")
    }
    try writeShelfRequestProfile(url: url, to: profile)
    guard try deploy() == url else {
        throw CommandError(message: "Cloudflare moved the access-request worker away from \(url).")
    }
    let configuration = ShelfRequestsConfiguration(url: url, adminToken: try saved?.adminToken ?? run("/usr/bin/openssl", ["rand", "-hex", "32"], log: nil))
    let secrets = directory.appendingPathComponent("secrets.json")
    try JSONEncoder().encode(["ADMIN_TOKEN": configuration.adminToken]).write(to: secrets)
    try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: secrets.path)
    defer { try? files.removeItem(at: secrets) }
    try wrangler(["secret", "bulk", "secrets.json"], directory: directory)
    try JSONEncoder().encode(configuration).write(to: ShelfRequestsConfiguration.path, options: .atomic)
    try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ShelfRequestsConfiguration.path.path)
    let session = URLSession(configuration: .ephemeral, delegate: RejectRedirect(), delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    guard let requests = try ShelfRequests.load(session: session) else {
        throw CommandError(message: "The access-request configuration was not saved.")
    }
    let deadline = Date().addingTimeInterval(60)
    while true {
        do {
            _ = try requests.workerRequest("/admin/requests", body: nil)
            break
        } catch {
            guard Date() < deadline else {
                throw CommandError(message: "The access-request worker does not accept this Mac's token yet: \(error.localizedDescription)")
            }
            Thread.sleep(forTimeInterval: 5)
        }
    }
    let store = try ShelfStore()
    try withShelfLock {
        let (release, catalog) = try store.catalog()
        var updated = catalog
        updated.invitation = "\(url)/"
        try store.updateBody(updated, releaseID: release.id)
    }
    let qrCode = files.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/uikit-app/ShelfInvite/AppShelf-request.png")
    try files.createDirectory(at: qrCode.deletingLastPathComponent(), withIntermediateDirectories: true)
    try writeQRCode("\(url)/", to: qrCode)
    try emit(["result": "shelf-requests-ready", "requestLink": "\(url)/", "qrCode": qrCode.path])
}
