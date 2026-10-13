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
    let shared = ShelfDevices(configuration: owner, sharing: ShelfSharing(devices: [ShelfSharedDevice(id: "FRIENDFONE", udid: "FRIEND-IPHONE", name: "Friend")], inviteGist: nil))

    func row(_ id: String, udid: String, status: String) -> [String: Any] {
        ["id": id, "udid": udid, "deviceName": "Phone \(id)", "model": "iPhone17,1", "systemVersion": "24A335", "status": status]
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

    reset(rows: [row("new", udid: "stranger-iphone", status: "pending"), row("own", udid: "OWNER-IPHONE", status: "pending"), row("old", udid: "x", status: "waiting")], records: [record("known", udid: "y", status: "waiting")])
    try requests.relay(devices: shared)
    try expect(operations() == ["create-new=waiting"], "New requests become owner-only CloudKit records")
    try expect(MockShelfProtocol.workerUpdates == ["new=waiting", "own=ready"], "Approved iPhones that ask again are ready without bothering the owner")

    reset(rows: [], records: [record("friend", udid: "friend-iphone", status: "preparing"), record("other", udid: "stranger-iphone", status: "preparing")])
    try requests.markReady(devices: shared)
    try expect(operations() == ["update-friend=ready"] && MockShelfProtocol.workerUpdates == ["friend=ready"], "Only iPhones in the signed set become ready")

    reset(rows: [], records: [record("friend", udid: "friend-iphone", status: "ready"), record("gone", udid: "stranger-iphone", status: "removing"), record("waiting", udid: "z", status: "waiting")])
    try requests.finish(devices: shared, failures: [])
    try expect(operations() == ["update-friend=shared", "forceDelete-gone"], "Finished shares and removals update only their own records")
    try expect(MockShelfProtocol.workerUpdates == ["friend=ready", "gone=removed"], "Visitors see ready or removed after the share run")

    reset(rows: [], records: [record("friend", udid: "friend-iphone", status: "ready")])
    try requests.finish(devices: shared, failures: ["Magic Touch: build failed"])
    let failedDetail = ((MockShelfProtocol.cloudOperations.first?["record"] as? [String: Any])?["fields"] as? [String: Any]).flatMap { ($0["detail"] as? [String: Any])?["value"] as? String }
    try expect(operations() == ["update-friend=failed"] && failedDetail == "Magic Touch: build failed", "Partial failures stay visible with their reason")

    reset(rows: [], records: [record("friend", udid: "friend-iphone", status: "preparing"), record("gone", udid: "stranger-iphone", status: "removing")])
    try requests.fail(devices: shared, detail: "AppShelf did not build")
    try expect(operations() == ["update-friend=failed", "update-gone=remove-failed"], "A failed share run stops instead of retrying forever")

    reset(rows: [], records: [record("good", udid: "a", status: "waiting"), ["recordName": "broken", "recordChangeTag": "tag", "fields": [:]]])
    try expect(try requests.records().map(\.name) == ["good"], "One malformed record cannot block every other request")
}
