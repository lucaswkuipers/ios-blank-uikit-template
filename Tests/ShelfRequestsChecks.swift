import CryptoKit
import Foundation

final class MockShelfProtocol: URLProtocol {
    static var workerRows: [[String: Any]] = []
    static var cloudRecords: [[String: Any]] = []
    static var workerUpdates: [String] = []
    static var cloudOperations: [[String: Any]] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        let body = request.httpBody ?? request.httpBodyStream.map { stream in
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else {
                    break
                }
                data.append(buffer, count: count)
            }
            return data
        } ?? Data()
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        let response: Any
        if path == "/admin/requests" {
            response = Self.workerRows
        } else if path.hasPrefix("/admin/") {
            Self.workerUpdates.append("\(path.split(separator: "/").last!)=\(json["status"] ?? json["link"] ?? "")")
            response = ["updated": 1]
        } else if path.hasSuffix("/records/query") {
            response = ["records": Self.cloudRecords]
        } else if path.hasSuffix("/records/lookup") {
            let names = (json["records"] as? [[String: Any]] ?? []).compactMap { $0["recordName"] as? String }
            response = ["records": names.map { name in
                Self.cloudRecords.first { $0["recordName"] as? String == name } ?? ["recordName": name, "serverErrorCode": "NOT_FOUND"]
            }]
        } else {
            let operations = json["operations"] as? [[String: Any]] ?? []
            Self.cloudOperations += operations
            response = ["records": operations.map { ($0["record"] as? [String: Any]) ?? [:] }]
        }
        let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: response))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

func testShelfRequests(directory: URL) throws {
    let key = P256.Signing.PrivateKey()
    let keyPath = directory.appendingPathComponent("requests-key.pem")
    try key.pemRepresentation.write(to: keyPath, atomically: true, encoding: .utf8)
    let settings = URLSessionConfiguration.ephemeral
    settings.protocolClasses = [MockShelfProtocol.self]
    let session = URLSession(configuration: settings)
    defer { session.invalidateAndCancel() }
    let cloud = try ShelfNotificationPublisher(configuration: ShelfNotificationConfiguration(keyID: "test-key", keyPath: keyPath.path, enabledAt: .distantPast), session: session)
    let requests = ShelfRequests(configuration: ShelfRequestsConfiguration(url: "https://worker.invalid", adminToken: "token"), cloud: cloud, session: session)
    let owner = DirectConfiguration(certificateID: "CERTIFICAT", certificateSHA1: "SHA1", deviceID: "OWNERPHONE", deviceUDID: "owner-iphone")
    let friend = ShelfSharedDevice(id: "FRIENDFONE", udid: "FRIEND-IPHONE", name: "Friend")
    let sharing = ShelfSharing(devices: [friend], inviteGist: nil)
    let shared = ShelfDevices(configuration: owner, sharing: sharing)
    let identifier = { (name: String) in "\(name)-0000-0000-0000-000000000000".prefix(36).description }
    let new = "11111111-1111-1111-1111-111111111111"
    let own = "22222222-2222-2222-2222-222222222222"

    func row(_ id: String, udid: String, status: String) -> [String: Any] {
        ["id": id, "udid": udid, "deviceName": "Phone\u{202E} \u{1B}[2J", "model": "iPhone17,1", "systemVersion": "24A335", "status": status]
    }

    func record(_ name: String, udid: String, status: String) -> [String: Any] {
        ["recordName": name, "recordChangeTag": "tag-\(name)", "recordType": "ShelfAccessRequest", "fields": ["udid": ["value": udid], "deviceName": ["value": "Phone \(name)"], "status": ["value": status]]]
    }

    func reset(rows: [[String: Any]], records: [[String: Any]]) {
        MockShelfProtocol.workerRows = rows
        MockShelfProtocol.cloudRecords = records
        MockShelfProtocol.workerUpdates = []
        MockShelfProtocol.cloudOperations = []
    }

    func operations() -> [String] {
        MockShelfProtocol.cloudOperations.map { operation in
            let record = operation["record"] as? [String: Any] ?? [:]
            let fields = record["fields"] as? [String: Any] ?? [:]
            let status = (fields["status"] as? [String: Any])?["value"] as? String ?? ""
            return "\(operation["operationType"] ?? "")-\(record["recordName"] ?? "")\(status.isEmpty ? "" : "=\(status)")"
        }
    }

    func field(_ name: String, of index: Int) -> String? {
        let record = MockShelfProtocol.cloudOperations[index]["record"] as? [String: Any]
        return ((record?["fields"] as? [String: Any])?[name] as? [String: Any])?["value"] as? String
    }

    reset(rows: [row(new, udid: "stranger-iphone", status: "pending"), row(own, udid: "OWNER-IPHONE", status: "pending")], records: [])
    try requests.relay(devices: shared)
    try expect(operations() == ["create-\(new)=waiting", "create-\(own)=waiting"], "Requests from iPhones without an installable shared record need the owner's approval")
    try expect(field("deviceName", of: 0) == "Phone [2J", "Device names lose control and direction-override characters")
    try expect(field("detail", of: 1) == "This iPhone already has access and asked again." && field("detail", of: 0) == "", "Repeat requests from approved iPhones are labeled")
    try expect(MockShelfProtocol.workerUpdates == ["\(new)=waiting", "\(own)=waiting"], "Visitors learn the owner was notified")

    reset(rows: [row(new, udid: "stranger-iphone", status: "pending")], records: [record(new, udid: "stranger-iphone", status: "waiting")])
    try requests.relay(devices: shared)
    try expect(operations().isEmpty && MockShelfProtocol.workerUpdates == ["\(new)=waiting"], "A relayed request is not created twice")

    reset(rows: [row(new, udid: "FRIEND-IPHONE", status: "pending")], records: [record(own, udid: "FRIEND-IPHONE", status: "shared")])
    try requests.relay(devices: shared)
    try expect(operations().isEmpty && MockShelfProtocol.workerUpdates == ["\(new)=ready"], "A shared iPhone asking again gets the install link without another approval")

    let friendRequest = identifier("33333333")
    let strangerRequest = identifier("44444444")
    reset(rows: [], records: [record(friendRequest, udid: "friend-iphone", status: "preparing"), record(strangerRequest, udid: "stranger-iphone", status: "preparing")])
    requests.markReady(devices: shared)
    try expect(operations() == ["update-\(friendRequest)=ready"] && MockShelfProtocol.workerUpdates == ["\(friendRequest)=ready"], "Only iPhones in the signed set become ready")

    let removed = identifier("55555555")
    let declined = identifier("66666666")
    reset(rows: [], records: [record(friendRequest, udid: "friend-iphone", status: "ready"), record(removed, udid: "stranger-iphone", status: "removing"), record(declined, udid: "z", status: "declined")])
    requests.finish(devices: shared, sharing: sharing, unavailable: [])
    try expect(operations() == ["update-\(friendRequest)=shared", "forceDelete-\(removed)"], "Finished shares and removals update only their own records")
    try expect(MockShelfProtocol.workerUpdates == ["\(friendRequest)=ready", "\(removed)=removed"], "Visitors see ready or removed after the share run")

    reset(rows: [], records: [record(friendRequest, udid: "friend-iphone", status: "ready")])
    requests.finish(devices: shared, sharing: sharing, unavailable: ["Magic Touch"])
    try expect(operations() == ["update-\(friendRequest)=shared"] && field("detail", of: 0) == "Still preparing for this iPhone: Magic Touch", "A share succeeds once AppShelf works and lists apps still preparing")

    reset(rows: [], records: [record(friendRequest, udid: "friend-iphone", status: "shared")])
    requests.finish(devices: ShelfDevices(configuration: owner, sharing: ShelfSharing(devices: [], inviteGist: nil)), sharing: ShelfSharing(devices: [], inviteGist: nil), unavailable: [])
    try expect(operations() == ["forceDelete-\(friendRequest)"] && MockShelfProtocol.workerUpdates == ["\(friendRequest)=removed"], "Removing an iPhone from the command line also removes it from AppShelf")

    var older = record(friendRequest, udid: "friend-iphone", status: "shared")
    older["created"] = ["timestamp": 1000.0]
    var newer = record(removed, udid: "FRIEND-IPHONE", status: "ready")
    newer["created"] = ["timestamp": 2000.0]
    reset(rows: [], records: [older, newer])
    requests.finish(devices: shared, sharing: sharing, unavailable: [])
    try expect(operations() == ["update-\(removed)=shared", "delete-\(friendRequest)"], "An iPhone that asked again is listed once, under its newest request")

    reset(rows: [], records: [record(friendRequest, udid: "friend-iphone", status: "removing")])
    requests.finish(devices: shared, sharing: sharing, unavailable: [])
    try expect(operations() == ["update-\(friendRequest)=remove-failed"], "A removal that did not apply stops in a visible state")

    reset(rows: [], records: [])
    requests.finish(devices: shared, sharing: sharing, unavailable: [])
    try expect(operations() == ["create-device-FRIENDFONE=shared"] && MockShelfProtocol.workerUpdates.isEmpty, "iPhones added from the command line appear in AppShelf without notifying the owner")

    reset(rows: [], records: [record(friendRequest, udid: "friend-iphone", status: "preparing"), record(removed, udid: "stranger-iphone", status: "removing"), record(declined, udid: "friend-iphone", status: "ready")])
    requests.fail(devices: shared, detail: "AppShelf did not build")
    try expect(operations() == ["update-\(friendRequest)=failed", "update-\(removed)=remove-failed"], "A failed share run stops in visible states")
    try expect(MockShelfProtocol.workerUpdates == ["\(friendRequest)=failed"], "Visitors who can already install AppShelf are not told it failed")

    reset(rows: [], records: [record("good", udid: "a", status: "waiting"), ["recordName": "broken", "recordChangeTag": "tag", "fields": [:]]])
    try expect(try requests.records().map(\.name) == ["good"], "One malformed record cannot block every other request")

    var memory = ShelfResignMemory(failures: [:])
    let start = Date(timeIntervalSince1970: 1_000_000)
    let application = ShelfApplication(name: "Magic Touch", bundleIdentifier: "com.lucaswkuipers.MagicTouch", version: "4.0", build: "14", minimumOSVersion: "27.0", profileExpiration: .distantFuture, sourceCommit: "commit", sha256: "digest", size: 1, packageAssetID: 1, publishedAt: start)
    try expect(outstandingResigns(ShelfCatalog(schema: 1, applications: [application], invitation: nil), devices: shared, memory: memory, at: start).count == 1, "Apps signed for an older device set need re-signing")
    memory.record(application, devices: shared, reason: "build failed", at: start)
    try expect(memory.blocks(application, devices: shared, at: start.addingTimeInterval(1799)) && !memory.blocks(application, devices: shared, at: start.addingTimeInterval(1801)), "The first retry waits 30 minutes")
    memory.record(application, devices: shared, reason: "build failed", at: start)
    memory.record(application, devices: shared, reason: "build failed", at: start)
    try expect(memory.failures[application.bundleIdentifier]?.attempts == 3 && memory.blocks(application, devices: shared, at: start.addingTimeInterval(7199)), "Retries back off exponentially")
    for _ in 0..<10 {
        memory.record(application, devices: shared, reason: "build failed", at: start)
    }
    try expect(!memory.blocks(application, devices: shared, at: start.addingTimeInterval(86401)), "Retries happen at least daily")
    var changed = application
    changed.deviceSet = nil
    let other = ShelfDevices(configuration: owner, sharing: ShelfSharing(devices: [friend, ShelfSharedDevice(id: "OTHERPHONE", udid: "other", name: "Other")], inviteGist: nil))
    try expect(!memory.blocks(changed, devices: other, at: start), "A new device set retries right away")
    try expect(shelfDisplayName("\u{202E}\u{1B}") == "iPhone" && shelfDisplayName("  Alex’s iPhone  ") == "Alex’s iPhone", "Display names keep readable text only")
}
