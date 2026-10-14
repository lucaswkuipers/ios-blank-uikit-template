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
    let detail: String

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
        detail = value("detail") ?? ""
    }
}

struct ShelfResignFailure: Codable {
    let commit: String
    let deviceSet: String
    let attempts: Int
    let retryAfter: Date
    let reason: String
}

struct ShelfResignMemory: Codable {
    static let path = TestFlightConfiguration.directory.appendingPathComponent("shelf-resign-failures.json")

    var failures: [String: ShelfResignFailure]

    static func load() throws -> Self {
        guard files.fileExists(atPath: path.path) else {
            return Self(failures: [:])
        }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: path))
    }

    func save() throws {
        try JSONEncoder().encode(self).write(to: Self.path, options: .atomic)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.path.path)
    }

    func blocks(_ application: ShelfApplication, devices: ShelfDevices, at date: Date) -> Bool {
        guard let failure = failures[application.bundleIdentifier] else {
            return false
        }
        return failure.commit == application.sourceCommit && failure.deviceSet == devices.identifier && failure.retryAfter > date
    }

    mutating func record(_ application: ShelfApplication, devices: ShelfDevices, reason: String, at date: Date) {
        let previous = failures[application.bundleIdentifier]
        let repeated = previous?.commit == application.sourceCommit && previous?.deviceSet == devices.identifier
        let attempts = repeated ? (previous?.attempts ?? 0) + 1 : 1
        let delay = min(1800 * pow(2, Double(attempts - 1)), 86400)
        failures[application.bundleIdentifier] = ShelfResignFailure(commit: application.sourceCommit, deviceSet: devices.identifier, attempts: attempts, retryAfter: date.addingTimeInterval(delay), reason: reason)
    }
}

func outstandingResigns(_ catalog: ShelfCatalog, devices: ShelfDevices, memory: ShelfResignMemory, at date: Date) -> [ShelfApplication] {
    catalog.applications.filter { !devices.isCurrent($0) && !memory.blocks($0, devices: devices, at: date) }
}

func shelfDisplayName(_ name: String) -> String {
    let hidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}"))
    let visible = String(String.UnicodeScalarView(name.unicodeScalars.filter { !hidden.contains($0) })).trimmingCharacters(in: .whitespaces)
    return visible.isEmpty ? "iPhone" : String(visible.prefix(50))
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

    func updateWorker(_ id: String, status visitorStatus: String) throws {
        guard UUID(uuidString: id) != nil else {
            return
        }
        do {
            _ = try workerRequest("/admin/requests/\(id.lowercased())", body: ["status": visitorStatus])
        } catch let error as AppleHTTPError where error.status == 404 {
            status("The request page no longer has request \(id); skipping its page update.")
        }
    }

    func setInstallLink(_ link: String) throws {
        for attempt in 1...3 {
            do {
                _ = try workerRequest("/admin/install", body: ["link": link])
                return
            } catch {
                guard attempt < 3 else {
                    throw CommandError(message: "The request page did not accept the new AppShelf install link: \(error.localizedDescription)")
                }
                Thread.sleep(forTimeInterval: Double(attempt * 5))
            }
        }
    }

    func records() throws -> [ShelfAccessRecord] {
        let results = try cloud.records(operation: "query", body: ["query": ["recordType": "ShelfAccessRequest"], "resultsLimit": 200])
        if let failure = results.first(where: { $0["serverErrorCode"] != nil }) {
            throw CommandError(message: "CloudKit could not list access requests: \(failure["serverErrorCode"] ?? "unknown error") \(failure["reason"] ?? "").")
        }
        return results.compactMap { record in
            do {
                return try ShelfAccessRecord(record)
            } catch {
                status(error.localizedDescription)
                return nil
            }
        }
    }

    func lookup(_ name: String) throws -> ShelfAccessRecord? {
        let results = try cloud.records(operation: "lookup", body: ["records": [["recordName": name]]])
        guard results.count == 1, let result = results.first else {
            throw CommandError(message: "CloudKit returned no lookup result for access request \(name).")
        }
        if result["serverErrorCode"] as? String == "NOT_FOUND" {
            return nil
        }
        if let failure = result["serverErrorCode"] {
            throw CommandError(message: "CloudKit could not read access request \(name): \(failure) \(result["reason"] ?? "").")
        }
        return try ShelfAccessRecord(result)
    }

    func modify(_ operation: [String: Any]) throws {
        let results = try cloud.records(operation: "modify", body: ["operations": [operation]])
        guard results.count == 1, results[0]["serverErrorCode"] == nil else {
            throw CommandError(message: "CloudKit did not save the access request: \(results.first?["serverErrorCode"] ?? "no result") \(results.first?["reason"] ?? "").")
        }
    }

    func create(name: String, udid: String, deviceName: String, model: String, systemVersion: String, status: String, detail: String) throws {
        let fields = ["deviceName": deviceName, "model": model, "systemVersion": systemVersion, "udid": udid, "status": status, "detail": detail]
        try modify(["operationType": "create", "record": ["recordType": "ShelfAccessRequest", "recordName": name, "fields": fields.mapValues { ["value": $0] }]])
    }

    @discardableResult
    func transition(_ name: String, from statuses: [String], to status: String, detail: String) throws -> Bool {
        guard let record = try lookup(name), statuses.contains(record.status) else {
            return false
        }
        let fields = ["status": ["value": status], "detail": ["value": String(detail.prefix(500))]]
        try modify(["operationType": "update", "record": ["recordType": "ShelfAccessRequest", "recordName": record.name, "recordChangeTag": record.changeTag, "fields": fields]])
        return true
    }

    func delete(_ name: String) throws {
        try modify(["operationType": "forceDelete", "record": ["recordName": name]])
    }

    func isolate(_ record: ShelfAccessRecord, _ work: () throws -> Void) {
        do {
            try work()
        } catch {
            status("Could not update the access request for \(record.deviceName); a later refresh retries: \(error.localizedDescription)")
        }
    }

    func relay(devices: ShelfDevices) throws {
        let pending = try JSONDecoder().decode([ShelfWorkerRequest].self, from: workerRequest("/admin/requests", body: nil))
        for request in pending {
            let deviceName = shelfDisplayName(request.deviceName)
            do {
                if try lookup(request.id) == nil {
                    let detail = devices.includes(request.udid) ? "This iPhone already has access and asked again." : ""
                    try create(name: request.id, udid: request.udid, deviceName: deviceName, model: shelfDisplayName(request.model), systemVersion: shelfDisplayName(request.systemVersion), status: "waiting", detail: detail)
                }
                try updateWorker(request.id, status: "waiting")
                status("Asked the shelf owner to approve \(deviceName).")
            } catch {
                status("Could not pass on the request from \(deviceName); a later refresh retries: \(error.localizedDescription)")
            }
        }
    }

    func markReady(devices: ShelfDevices) {
        do {
            for record in try records() where ["preparing", "failed"].contains(record.status) && devices.includes(record.udid) {
                isolate(record) {
                    try updateWorker(record.name, status: "ready")
                    try transition(record.name, from: ["preparing", "failed"], to: "ready", detail: "")
                }
            }
        } catch {
            status("Could not list access requests to mark them ready: \(error.localizedDescription)")
        }
    }

    func finish(devices: ShelfDevices, sharing: ShelfSharing, unavailable: [String]) {
        let detail = unavailable.isEmpty ? "" : "Still preparing for this iPhone: " + unavailable.joined(separator: ", ")
        do {
            let records = try records()
            for record in records {
                isolate(record) {
                    let included = devices.includes(record.udid)
                    if included && ["preparing", "ready", "failed", "shared"].contains(record.status) {
                        try updateWorker(record.name, status: "ready")
                        if record.status != "shared" || record.detail != detail {
                            try transition(record.name, from: [record.status], to: "shared", detail: detail)
                        }
                    } else if !included && ["preparing", "ready", "shared", "remove", "removing", "remove-failed"].contains(record.status) {
                        try updateWorker(record.name, status: "removed")
                        try delete(record.name)
                    } else if included && record.status == "removing" {
                        try transition(record.name, from: ["removing"], to: "remove-failed", detail: "This iPhone is still in the shelf's signing list.")
                    }
                }
            }
            let recorded = Set(records.filter { !["declined", "failed"].contains($0.status) }.map { $0.udid.lowercased() })
            for device in sharing.devices where !recorded.contains(device.udid.lowercased()) {
                do {
                    if try lookup("device-\(device.id)") == nil {
                        try create(name: "device-\(device.id)", udid: device.udid, deviceName: device.name, model: "", systemVersion: "", status: "shared", detail: detail)
                    }
                } catch {
                    status("Could not list \(device.name) in AppShelf's Sharing screen: \(error.localizedDescription)")
                }
            }
        } catch {
            status("Could not list access requests to finish them: \(error.localizedDescription)")
        }
    }

    func fail(devices: ShelfDevices, detail: String) {
        do {
            for record in try records() {
                isolate(record) {
                    if record.status == "preparing" && devices.includes(record.udid) {
                        try updateWorker(record.name, status: "failed")
                        try transition(record.name, from: ["preparing"], to: "failed", detail: detail)
                    } else if record.status == "removing" {
                        try transition(record.name, from: ["removing"], to: "remove-failed", detail: detail)
                    }
                }
            }
        } catch {
            status("Could not list access requests to mark them failed: \(error.localizedDescription)")
        }
    }
}

func processShelfRequests(store: ShelfStore) {
    do {
        let session = URLSession(configuration: .ephemeral, delegate: RejectRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        guard let requests = try ShelfRequests.load(session: session) else {
            return
        }
        try requests.relay(devices: try ShelfDevices.load())
        let records = try requests.records()
        for record in records where record.status == "declined" {
            requests.isolate(record) {
                try requests.updateWorker(record.name, status: "declined")
                try requests.delete(record.name)
            }
        }
        guard try shelfShareIsIdle() else {
            return
        }
        var changed = false
        for record in records where record.status == "approved" {
            requests.isolate(record) {
                do {
                    try addShelfDevice(udid: record.udid, name: record.deviceName)
                } catch {
                    status("Could not approve \(record.deviceName): \(error.localizedDescription)")
                    if try requests.transition(record.name, from: ["approved"], to: "failed", detail: error.localizedDescription) {
                        try requests.updateWorker(record.name, status: "failed")
                    }
                    return
                }
                try ShelfResignMemory(failures: [:]).save()
                if try requests.transition(record.name, from: ["approved"], to: "preparing", detail: "") {
                    try requests.updateWorker(record.name, status: "preparing")
                }
                changed = true
            }
        }
        let owner = try DirectConfiguration.load().deviceUDID
        for record in records where record.status == "remove" {
            requests.isolate(record) {
                guard owner.caseInsensitiveCompare(record.udid) != .orderedSame else {
                    try requests.transition(record.name, from: ["remove"], to: "shared", detail: "This is the shelf owner's iPhone, which always keeps access.")
                    return
                }
                if try ShelfSharing.load().devices.contains(where: { $0.udid.caseInsensitiveCompare(record.udid) == .orderedSame }) {
                    try removeShelfDevice(record.udid)
                }
                try requests.transition(record.name, from: ["remove"], to: "removing", detail: "")
                changed = true
            }
        }
        let (_, catalog) = try store.catalog()
        let outstanding = !outstandingResigns(catalog, devices: try ShelfDevices.load(), memory: try ShelfResignMemory.load(), at: Date()).isEmpty
        let unfinished = records.contains { ["preparing", "ready", "removing"].contains($0.status) }
        let due = try shelfShareSpawnedBefore(Date().addingTimeInterval(-600))
        guard changed || ((outstanding || unfinished) && due) else {
            return
        }
        try spawnShelfShare()
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

func shelfShareSpawnedBefore(_ date: Date) throws -> Bool {
    let marker = TestFlightConfiguration.directory.appendingPathComponent("shelf-share.spawned")
    guard files.fileExists(atPath: marker.path) else {
        return true
    }
    guard let modified = try files.attributesOfItem(atPath: marker.path)[.modificationDate] as? Date else {
        throw CommandError(message: "Cannot read when the shelf was last re-signed.")
    }
    return modified < date
}

func spawnShelfShare() throws {
    try Data().write(to: TestFlightConfiguration.directory.appendingPathComponent("shelf-share.spawned"), options: .atomic)
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
    let inherited = ProcessInfo.processInfo.environment
    var environment = ["HOME", "USER", "LOGNAME", "LANG", "TMPDIR"].reduce(into: [String: String]()) { values, key in
        values[key] = inherited[key]
    }
    environment["PATH"] = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    environment["npm_config_cache"] = files.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/uikit-app/npm").path
    environment["WRANGLER_SEND_METRICS"] = "false"
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
    struct Account: Decodable {
        let id: String
        let name: String
    }
    struct Identity: Decodable {
        let loggedIn: Bool
        let accounts: [Account]?
    }
    let login = RequiredAction(result: "needs-cloudflare-login", message: "Sign in to the free Cloudflare account in the browser, then rerun setup-shelf-requests.", command: "npm_config_cache=$HOME/Library/Caches/uikit-app/npm npx --yes wrangler@4.143.0 login")
    let identity: Identity
    do {
        identity = try JSONDecoder().decode(Identity.self, from: Data(wrangler(["whoami", "--json"], directory: directory).utf8))
    } catch {
        status("Cloudflare login check: \(error.localizedDescription)")
        throw login
    }
    guard identity.loggedIn, let accounts = identity.accounts else {
        throw login
    }
    guard accounts.count == 1, let account = accounts.first else {
        throw CommandError(message: "Cloudflare login has \(accounts.count) accounts (\(accounts.map(\.name).joined(separator: ", "))); setup needs exactly one free personal account.")
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
    let installLink = try shelfInstallLink(manifestURL: "https://gist.githubusercontent.com/lucaswkuipers/\(gist)/raw/AppShelf.plist")
    let store = try ShelfStore()
    let (_, catalog) = try store.catalog()
    guard let shelf = catalog.applications.first(where: { $0.bundleIdentifier == "com.lucaswkuipers.AppShelf" }) else {
        throw CommandError(message: "AppShelf is missing from the shelf catalog.")
    }
    let manifest = """
    name = "appshelf"
    account_id = "\(account.id)"
    main = "worker.js"
    compatibility_date = "2026-09-01"
    workers_dev = true
    preview_urls = false
    rules = [{ type = "Data", globs = ["**/*.mobileconfig"], fallthrough = false }]

    [vars]
    OWNER_NAME = "Lucas"
    INSTALL_LINK = "\(installLink)"
    INSTALL_PREFIX = "\(try shelfInstallLink(manifestURL: "https://gist.githubusercontent.com/lucaswkuipers/\(gist)/raw/"))"
    MINIMUM_SYSTEM = "\(shelf.minimumOSVersion)"

    [[d1_databases]]
    binding = "DB"
    database_name = "appshelf-requests"
    database_id = "\(database.uuid)"

    """
    try manifest.write(to: directory.appendingPathComponent("wrangler.toml"), atomically: true, encoding: .utf8)
    try wrangler(["d1", "execute", "appshelf-requests", "--remote", "--command", String(contentsOf: directory.appendingPathComponent("schema.sql"), encoding: .utf8), "--yes"], directory: directory)
    let saved = try ShelfRequestsConfiguration.load()
    let adminToken = try saved?.adminToken ?? run("/usr/bin/openssl", ["rand", "-hex", "32"], log: nil)
    let secrets = directory.appendingPathComponent("secrets.json")
    try JSONEncoder().encode(["ADMIN_TOKEN": adminToken]).write(to: secrets)
    try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: secrets.path)
    defer { try? files.removeItem(at: secrets) }
    let profile = directory.appendingPathComponent("request.mobileconfig")
    func deploy() throws -> String {
        do {
            let output = try wrangler(["deploy", "--secrets-file", "secrets.json"], directory: directory)
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
    let configuration = ShelfRequestsConfiguration(url: url, adminToken: adminToken)
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
