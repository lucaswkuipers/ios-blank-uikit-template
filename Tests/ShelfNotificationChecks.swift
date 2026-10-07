import CryptoKit
import Foundation

final class MockCloudKitProtocol: URLProtocol {
    static var responses: [(Int, [String: Any])] = []
    static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        let (status, body) = Self.responses.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: body))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

func testShelfNotifications(directory: URL) throws {
    let key = P256.Signing.PrivateKey()
    let keyPath = directory.appendingPathComponent("notification-key.pem")
    try key.pemRepresentation.write(to: keyPath, atomically: true, encoding: .utf8)
    let configuration = ShelfNotificationConfiguration(keyID: "test-key", keyPath: keyPath.path, enabledAt: .distantPast)
    let settings = URLSessionConfiguration.ephemeral
    settings.protocolClasses = [MockCloudKitProtocol.self]
    let session = URLSession(configuration: settings)
    defer { session.invalidateAndCancel() }
    let publisher = try ShelfNotificationPublisher(configuration: configuration, session: session)
    let application = ShelfApplication(name: "Example", bundleIdentifier: "com.lucaswkuipers.Example", version: "1.0", build: "7", minimumOSVersion: "27.0", profileExpiration: .distantFuture, sourceCommit: "commit-seven", sha256: "private-digest", size: 42, packageAssetID: 123, publishedAt: Date(), manifestAssetID: 456, installExpiration: .distantFuture, notificationTitle: "New app available")
    let announcement = ShelfAnnouncement(application: application)
    var refreshed = application
    refreshed.manifestAssetID = 999
    refreshed.installExpiration = Date().addingTimeInterval(600)
    try expect(ShelfAnnouncement(application: refreshed).recordName == announcement.recordName, "Refreshing install links must not produce a second notification")
    let body = ["operations": [["operationType": "create", "record": announcement.record]]]
    let request = try publisher.request(operation: "modify", body: body, date: Date(timeIntervalSince1970: 1000))
    let timestamp = request.value(forHTTPHeaderField: "X-Apple-CloudKit-Request-ISO8601Date")!
    let digest = Data(SHA256.hash(data: request.httpBody!)).base64EncodedString()
    let message = Data("\(timestamp):\(digest):\(request.url!.path)".utf8)
    let signature = try P256.Signing.ECDSASignature(derRepresentation: Data(base64Encoded: request.value(forHTTPHeaderField: "X-Apple-CloudKit-Request-SignatureV1")!)!)
    try expect(key.publicKey.isValidSignature(signature, for: message), "CloudKit requests must use valid DER signatures over date, body digest and path")
    let text = String(decoding: request.httpBody!, as: UTF8.self)
    try expect(!text.contains("private-digest") && !text.contains("commit-seven") && !text.contains("packageAssetID"), "Announcements must not disclose download or source metadata")
    let missing: [String: Any] = ["records": [["recordName": announcement.recordName, "serverErrorCode": "NOT_FOUND"]]]
    let saved: [String: Any] = ["records": [announcement.record]]
    MockCloudKitProtocol.requests = []
    MockCloudKitProtocol.responses = [(200, missing), (200, saved)]
    try publisher.send(announcement)
    try expect(MockCloudKitProtocol.requests.count == 2, "New announcements must be created")
    MockCloudKitProtocol.requests = []
    MockCloudKitProtocol.responses = [(200, saved)]
    try publisher.send(announcement)
    try expect(MockCloudKitProtocol.requests.count == 1, "A retry after lost success must not create another notification")
    MockCloudKitProtocol.responses = [(200, ["records": [["serverErrorCode": "ACCESS_DENIED"]]])]
    try expectFailure { try publisher.send(announcement) }
    MockCloudKitProtocol.responses = [(200, missing), (503, [:])]
    try expectFailure { try publisher.send(announcement) }
    MockCloudKitProtocol.responses = [(200, missing), (200, ["records": [["serverErrorCode": "QUOTA_EXCEEDED"]]])]
    try expectFailure { try publisher.send(announcement) }
    MockCloudKitProtocol.responses = [(200, [:])]
    try expectFailure { try publisher.send(announcement) }
    try expect(MockCloudKitProtocol.responses.isEmpty, "All expected CloudKit responses must be consumed")
}
