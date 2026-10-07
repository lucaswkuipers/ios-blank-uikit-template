import CryptoKit
import Foundation

struct ShelfNotificationConfiguration: Decodable {
    let keyID: String
    let keyPath: String
    let enabledAt: Date

    static func load() throws -> Self? {
        let path = TestFlightConfiguration.directory.appendingPathComponent("shelf-notifications.json")
        guard files.fileExists(atPath: path.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Self.self, from: Data(contentsOf: path))
    }
}

struct ShelfAnnouncement {
    let application: ShelfApplication

    var recordName: String {
        let identity = "\(application.bundleIdentifier):\(application.build):\(application.sourceCommit)"
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    var record: [String: Any] {
        ["recordType": "ShelfAnnouncement", "recordName": recordName, "fields": [
            "title": ["value": application.notificationTitle ?? "Update available"],
            "body": ["value": "\(application.name) \(application.version) (\(application.build)) is ready in AppShelf."],
            "bundleIdentifier": ["value": application.bundleIdentifier]
        ]]
    }
}

struct ShelfNotificationPublisher {
    static let container = "iCloud.com.lucaswkuipers.AppShelf"
    let configuration: ShelfNotificationConfiguration
    let key: P256.Signing.PrivateKey
    let session: URLSession

    init(configuration: ShelfNotificationConfiguration, session: URLSession) throws {
        self.configuration = configuration
        key = try P256.Signing.PrivateKey(pemRepresentation: String(contentsOfFile: configuration.keyPath, encoding: .utf8))
        self.session = session
    }

    func request(operation: String, body: [String: Any], date: Date) throws -> URLRequest {
        let path = "/database/1/\(Self.container)/production/public/records/\(operation)"
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let timestamp = ISO8601DateFormatter().string(from: date)
        let digest = Data(SHA256.hash(data: data)).base64EncodedString()
        let signature = try key.signature(for: Data("\(timestamp):\(digest):\(path)".utf8)).derRepresentation.base64EncodedString()
        var request = URLRequest(url: URL(string: "https://api.apple-cloudkit.com\(path)")!)
        request.httpMethod = "POST"
        request.httpBody = data
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.keyID, forHTTPHeaderField: "X-Apple-CloudKit-Request-KeyID")
        request.setValue(timestamp, forHTTPHeaderField: "X-Apple-CloudKit-Request-ISO8601Date")
        request.setValue(signature, forHTTPHeaderField: "X-Apple-CloudKit-Request-SignatureV1")
        return request
    }

    func send(_ announcement: ShelfAnnouncement) throws {
        let lookup = try records(operation: "lookup", body: ["records": [["recordName": announcement.recordName]]])
        guard let existing = lookup.first, lookup.count == 1 else {
            throw CommandError(message: "CloudKit returned no announcement lookup result.")
        }
        if existing["recordName"] as? String == announcement.recordName, existing["recordType"] as? String == "ShelfAnnouncement", existing["serverErrorCode"] == nil {
            return
        }
        guard existing["serverErrorCode"] as? String == "NOT_FOUND" else {
            throw CommandError(message: "CloudKit announcement lookup failed: \(existing["serverErrorCode"] ?? "invalid response").")
        }
        let created = try records(operation: "modify", body: ["operations": [["operationType": "create", "record": announcement.record]]])
        guard created.count == 1, let result = created.first, result["serverErrorCode"] == nil,
              result["recordName"] as? String == announcement.recordName,
              result["recordType"] as? String == "ShelfAnnouncement" else {
            throw CommandError(message: "CloudKit did not confirm announcement creation. The next shelf refresh will reconcile and retry.")
        }
    }

    private func records(operation: String, body: [String: Any]) throws -> [[String: Any]] {
        let request = try request(operation: operation, body: body, date: Date())
        let data = try appleRequest(request, session: session)
        guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let records = response["records"] as? [[String: Any]] else {
            throw CommandError(message: "CloudKit returned an invalid notification response.")
        }
        return records
    }
}

func publishShelfNotifications(_ catalog: ShelfCatalog) throws {
    guard let configuration = try ShelfNotificationConfiguration.load() else { return }
    let path = TestFlightConfiguration.directory.appendingPathComponent("shelf-notifications-sent.json")
    var sent = files.fileExists(atPath: path.path) ? try JSONDecoder().decode([String: String].self, from: Data(contentsOf: path)) : [:]
    let session = URLSession(configuration: .ephemeral, delegate: RejectRedirect(), delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    let publisher = try ShelfNotificationPublisher(configuration: configuration, session: session)
    var failures: [String] = []
    for application in catalog.applications where application.publishedAt >= configuration.enabledAt {
        let announcement = ShelfAnnouncement(application: application)
        guard sent[application.bundleIdentifier] != announcement.recordName else { continue }
        guard application.profileExpiration > Date(), let expiration = application.installExpiration,
              expiration > Date().addingTimeInterval(60), application.manifestAssetID != nil else { continue }
        do {
            try publisher.send(announcement)
            sent[application.bundleIdentifier] = announcement.recordName
            try JSONEncoder().encode(sent).write(to: path, options: .atomic)
            try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
            status("Notification announcement accepted for \(application.name) build \(application.build).")
        } catch {
            failures.append("\(application.name): \(error.localizedDescription)")
        }
    }
    guard failures.isEmpty else {
        throw CommandError(message: "Apps are published, but notifications are pending retry on the next shelf refresh:\n" + failures.joined(separator: "\n"))
    }
}
