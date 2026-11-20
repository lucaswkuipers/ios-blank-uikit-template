import CryptoKit
import Foundation
import ImageIO
import zlib

struct ShelfApplication: Codable {
    let name: String
    let bundleIdentifier: String
    let version: String
    let build: String
    let minimumOSVersion: String
    let profileExpiration: Date
    let sourceCommit: String
    let sha256: String
    let size: Int
    let packageAssetID: Int
    let publishedAt: Date
    var manifestAssetID: Int?
    var installExpiration: Date?
    var iconPNG: String?
    var notificationTitle: String?
    var deviceSet: String?
    var silent: Bool?
    var releaseNotes: [String]?
    var platform: String?
}

struct ShelfCatalogAsset: Codable, Equatable {
    let id: Int
    let sha256: String
    let size: Int
}

struct ShelfCatalog: Codable {
    let schema: Int
    var applications: [ShelfApplication]
    var invitation: String?
    // Older AppShelf clients ignore this list, so visionOS apps never appear on iPhones.
    var visionApplications: [ShelfApplication]?
    // Only the owner's AppShelf lists these. Older clients, announcements and device re-signing never read this list.
    var ownerApplications: [ShelfApplication]?
    // Set in the release body, which older clients read whole: the complete catalog is this gzip'd release asset.
    var catalogAsset: ShelfCatalogAsset?

    var linkedAssetIDs: Set<Int> {
        var identifiers = Set(applications.compactMap(\.manifestAssetID))
        if let catalogAsset {
            identifiers.insert(catalogAsset.id)
        }
        return identifiers
    }

    func mapApplications(_ transform: (ShelfApplication) throws -> ShelfApplication) rethrows -> ShelfCatalog {
        var catalog = self
        catalog.applications = try applications.map(transform)
        catalog.visionApplications = try visionApplications?.map(transform)
        catalog.ownerApplications = try ownerApplications?.map(transform)
        return catalog
    }

    func applications(for platform: ShelfPlatform) -> [ShelfApplication] {
        platform == .iOS ? applications : visionApplications ?? []
    }

    mutating func setApplications(_ list: [ShelfApplication], for platform: ShelfPlatform) {
        if platform == .iOS { applications = list } else { visionApplications = list }
    }

    func applications(for metadata: Project, platform: ShelfPlatform) -> [ShelfApplication] {
        metadata.ownerOnly == true ? ownerApplications ?? [] : applications(for: platform)
    }

    // An app listed twice would make clients reject the catalog, so changing audience also leaves the other list.
    mutating func setApplications(_ list: [ShelfApplication], for metadata: Project, platform: ShelfPlatform) {
        if metadata.ownerOnly == true {
            ownerApplications = list
            applications.removeAll { $0.bundleIdentifier == metadata.bundleIdentifier }
        } else {
            setApplications(list, for: platform)
            ownerApplications?.removeAll { $0.bundleIdentifier == metadata.bundleIdentifier }
        }
    }
}

// GitHub allows 125,000 characters per release description, and older AppShelf clients read nothing else. The body
// keeps every app it can for them: smaller icons first, then none, then without the longest-unchanged apps, never
// AppShelf itself, so they can always update to a client that reads the complete catalog asset.
func shelfCatalogBody(_ catalog: ShelfCatalog, encoder: JSONEncoder) throws -> Data {
    var body = catalog
    var data = try encoder.encode(body)
    // Each listed app gets an install link on the next refresh, so one without a link yet keeps room for it.
    func overBudget() -> Bool {
        data.count + 80 * body.applications.filter { $0.manifestAssetID == nil }.count > 100_000
    }
    for maximumPixelSize in [64, 48, 32] where overBudget() {
        body = try catalog.mapApplications { try shelfThumbnail($0, maximumPixelSize: maximumPixelSize) }
        data = try encoder.encode(body)
    }
    if overBudget() {
        body = body.mapApplications { application in
            var application = application
            application.iconPNG = nil
            return application
        }
        data = try encoder.encode(body)
    }
    while overBudget() {
        let entries = body.applications + (body.visionApplications ?? []) + (body.ownerApplications ?? [])
        guard let oldest = entries.filter({ $0.bundleIdentifier != "com.lucaswkuipers.AppShelf" }).min(by: { $0.publishedAt < $1.publishedAt }) else {
            throw CommandError(message: "AppShelf's own catalog entries exceed GitHub's release-description budget.")
        }
        body.applications.removeAll { $0.packageAssetID == oldest.packageAssetID }
        body.visionApplications?.removeAll { $0.packageAssetID == oldest.packageAssetID }
        body.ownerApplications?.removeAll { $0.packageAssetID == oldest.packageAssetID }
        data = try encoder.encode(body)
    }
    return data
}

// Install links change every few minutes and only older clients use them, so they stay in the release body.
func shelfCatalogAsset(_ catalog: ShelfCatalog, encoder: JSONEncoder) throws -> Data {
    var complete = catalog.mapApplications { application in
        var application = application
        application.manifestAssetID = nil
        application.installExpiration = nil
        return application
    }
    complete.catalogAsset = nil
    return try shelfGzip(encoder.encode(complete))
}

func shelfCatalog(_ complete: ShelfCatalog, linkedFrom body: ShelfCatalog) -> ShelfCatalog {
    var catalog = complete.mapApplications { application in
        var application = application
        let listed = body.applications.first { $0.packageAssetID == application.packageAssetID }
        application.manifestAssetID = listed?.manifestAssetID
        application.installExpiration = listed?.installExpiration
        return application
    }
    catalog.catalogAsset = body.catalogAsset
    return catalog
}

func shelfThumbnail(_ application: ShelfApplication, maximumPixelSize: Int) throws -> ShelfApplication {
    guard let encoded = application.iconPNG else {
        return application
    }
    guard let icon = Data(base64Encoded: encoded),
          let source = CGImageSourceCreateWithData(icon as CFData, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int,
          let height = properties[kCGImagePropertyPixelHeight] as? Int else {
        throw CommandError(message: "Cannot read the catalog icon of \(application.name).")
    }
    guard max(width, height) > maximumPixelSize else {
        return application
    }
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize] as CFDictionary) else {
        throw CommandError(message: "Cannot resize a catalog thumbnail.")
    }
    let thumbnail = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(thumbnail, "public.png" as CFString, 1, nil) else {
        throw CommandError(message: "Cannot encode a catalog thumbnail.")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw CommandError(message: "Cannot finish a catalog thumbnail.")
    }
    var resized = application
    resized.iconPNG = (thumbnail as Data).base64EncodedString()
    return resized
}

func shelfGzip(_ data: Data) throws -> Data {
    var archive = Data([0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 3])
    archive.append(try (data as NSData).compressed(using: .zlib) as Data)
    let checksum = data.withUnsafeBytes { UInt32(crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count))) }
    for value in [checksum, UInt32(truncatingIfNeeded: data.count)] {
        withUnsafeBytes(of: value.littleEndian) { archive.append(contentsOf: $0) }
    }
    return archive
}

func shelfGunzip(_ archive: Data) throws -> Data {
    guard archive.count > 18, archive.starts(with: [0x1f, 0x8b, 8, 0]) else {
        throw CommandError(message: "The shelf catalog asset is not a plain gzip file.")
    }
    let data = try (Data(archive.dropFirst(10).dropLast(8)) as NSData).decompressed(using: .zlib) as Data
    let size = archive.suffix(4).map(UInt32.init)
    guard size[0] | size[1] << 8 | size[2] << 16 | size[3] << 24 == UInt32(truncatingIfNeeded: data.count) else {
        throw CommandError(message: "The shelf catalog asset is truncated.")
    }
    return data
}

struct ShelfDeliveryState: Codable {
    let commit: String
    let build: String

    static func reserve(bundle: String, commit: String, minimum: String, directory: URL) throws -> Self {
        try validate(bundle, pattern: "^com\\.lucaswkuipers\\.[A-Za-z0-9-]+(?:\\.[A-Za-z0-9-]+)*$", label: "personal bundle identifier")
        let path = directory.appendingPathComponent("direct-deliveries/\(bundle).json")
        if files.fileExists(atPath: path.path) {
            let saved = try JSONDecoder().decode(Self.self, from: Data(contentsOf: path))
            if saved.commit == commit, saved.build.compare(minimum, options: .numeric) != .orderedAscending {
                _ = try nextBuildNumber(saved.build)
                return saved
            }
        }
        let build = try reserveBuildNumber(bundle: bundle, minimum: minimum, directory: directory.appendingPathComponent("build-numbers"))
        let state = Self(commit: commit, build: build)
        try files.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(state).write(to: path, options: .atomic)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        return state
    }
}

struct ShelfAsset: Decodable {
    let id: Int
    let name: String
    let created_at: String
    let size: Int
    let digest: String?
}

struct ShelfRelease: Decodable {
    let id: Int
    let tag_name: String
    let body: String?
    let draft: Bool
    let assets: [ShelfAsset]
}

final class RejectRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

func shelfDownloadExpiration(_ url: URL) throws -> Date {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false), components.scheme == "https",
          components.host == "release-assets.githubusercontent.com", components.user == nil, components.password == nil,
          let text = components.queryItems?.first(where: { $0.name == "se" })?.value,
          let expiration = ISO8601DateFormatter().date(from: text),
          let token = components.queryItems?.first(where: { $0.name == "jwt" })?.value else {
        throw CommandError(message: "Unsupported GitHub download URL.")
    }
    let segments = token.split(separator: ".")
    guard segments.count == 3 else { throw CommandError(message: "Invalid GitHub download expiry.") }
    let encoded = String(segments[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    guard let data = Data(base64Encoded: encoded + String(repeating: "=", count: (4 - encoded.count % 4) % 4)),
          let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let seconds = payload["exp"] as? Double else { throw CommandError(message: "Missing GitHub download expiry.") }
    return min(expiration, Date(timeIntervalSince1970: seconds))
}

struct ShelfStore {
    static let repository = "lucaswkuipers/AppShelf-builds"
    static let catalogCache = files.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/uikit-app/ShelfCatalog")
    let github: PersonalGitHub
    let encoder: JSONEncoder
    let decoder: JSONDecoder

    init() throws {
        github = try PersonalGitHub()
        _ = try github.repository(name: "AppShelf-builds")
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func catalog() throws -> (ShelfRelease, ShelfCatalog) {
        let output = try github.call(["api", "repos/\(Self.repository)/releases/tags/catalog"])
        let release = try decoder.decode(ShelfRelease.self, from: Data(output.utf8))
        let body = try catalogBody(release)
        guard let asset = body.catalogAsset else {
            return (release, body)
        }
        let complete = try decoder.decode(ShelfCatalog.self, from: shelfGunzip(catalogAssetData(asset)))
        guard complete.schema == 1 else { throw CommandError(message: "Unsupported shelf catalog version.") }
        return (release, shelfCatalog(complete, linkedFrom: body))
    }

    func catalogBody(_ release: ShelfRelease) throws -> ShelfCatalog {
        guard !release.draft, let body = release.body else { throw CommandError(message: "Shelf catalog is unavailable.") }
        let catalog = try decoder.decode(ShelfCatalog.self, from: Data(body.utf8))
        guard catalog.schema == 1 else { throw CommandError(message: "Unsupported shelf catalog version.") }
        return catalog
    }

    func save(_ catalog: ShelfCatalog, release: ShelfRelease) throws {
        var body = catalog
        body.catalogAsset = try catalogAsset(shelfCatalogAsset(catalog, encoder: encoder), release: release)
        try updateBody(data: shelfCatalogBody(body, encoder: encoder), releaseID: release.id)
    }

    func updateBody(_ application: ShelfApplication, releaseID: Int) throws {
        try updateBody(data: encoder.encode(application), releaseID: releaseID)
    }

    private func updateBody(data: Data, releaseID: Int) throws {
        let temporary = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? files.removeItem(at: temporary) }
        let body = String(decoding: data, as: UTF8.self)
        try JSONSerialization.data(withJSONObject: ["body": body]).write(to: temporary, options: .atomic)
        try github.call(["api", "--method", "PATCH", "repos/\(Self.repository)/releases/\(releaseID)", "--input", temporary.path])
    }

    // Named by content, so an unchanged catalog reuses its asset and a missing one is uploaded again.
    private func catalogAsset(_ data: Data, release: ShelfRelease) throws -> ShelfCatalogAsset {
        let sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let name = "catalog-\(sha256).json.gz"
        if let existing = release.assets.first(where: { $0.name == name }) {
            if existing.size == data.count, existing.digest == "sha256:\(sha256)" {
                return ShelfCatalogAsset(id: existing.id, sha256: sha256, size: data.count)
            }
            try github.call(["api", "--method", "DELETE", "repos/\(Self.repository)/releases/assets/\(existing.id)"])
        }
        let temporary = files.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json.gz")
        defer { try? files.removeItem(at: temporary) }
        try data.write(to: temporary, options: .atomic)
        let asset = try upload(temporary, name: name, contentType: "application/gzip", releaseID: release.id)
        guard asset.size == data.count, asset.digest == "sha256:\(sha256)" else {
            throw CommandError(message: "GitHub's uploaded catalog size or checksum differs. The previous catalog was kept.")
        }
        try cacheCatalogAsset(data, sha256: sha256)
        return ShelfCatalogAsset(id: asset.id, sha256: sha256, size: data.count)
    }

    private func catalogAssetData(_ asset: ShelfCatalogAsset) throws -> Data {
        let cached = Self.catalogCache.appendingPathComponent("\(asset.sha256).json.gz")
        if let data = try? Data(contentsOf: cached), data.count == asset.size, SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == asset.sha256 {
            return data
        }
        let (url, _) = try downloadLink(assetID: asset.id)
        let temporary = files.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json.gz")
        defer { try? files.removeItem(at: temporary) }
        try run("/usr/bin/curl", ["--fail", "--silent", "--show-error", "--connect-timeout", "15", "--max-time", "120",
            "--output", temporary.path, url.absoluteString], log: nil)
        let data = try Data(contentsOf: temporary)
        guard data.count == asset.size, SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == asset.sha256 else {
            throw CommandError(message: "The downloaded shelf catalog differs from the checksum its release names.")
        }
        try cacheCatalogAsset(data, sha256: asset.sha256)
        return data
    }

    private func cacheCatalogAsset(_ data: Data, sha256: String) throws {
        let path = Self.catalogCache.appendingPathComponent("\(sha256).json.gz")
        try files.createDirectory(at: Self.catalogCache, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for name in try files.contentsOfDirectory(atPath: Self.catalogCache.path) where name.hasSuffix(".json.gz") && name != path.lastPathComponent {
            try? files.removeItem(at: Self.catalogCache.appendingPathComponent(name))
        }
        try data.write(to: path, options: .atomic)
    }

    func upload(_ file: URL, name: String, contentType: String, releaseID: Int) throws -> ShelfAsset {
        var components = URLComponents(string: "https://uploads.github.com/repos/\(Self.repository)/releases/\(releaseID)/assets")!
        components.queryItems = [URLQueryItem(name: "name", value: name)]
        let output = try github.call(["api", "--method", "POST", components.url!.absoluteString, "-H", "Content-Type: \(contentType)", "--input", file.path])
        return try decoder.decode(ShelfAsset.self, from: Data(output.utf8))
    }

    func downloadLink(assetID: Int) throws -> (URL, Date) {
        let delegate = RejectRedirect()
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repository)/releases/assets/\(assetID)?refresh=\(UUID().uuidString)")!)
        request.timeoutInterval = 45
        request.setValue("Bearer \(github.environment["GH_TOKEN"]!)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let completion = DispatchSemaphore(value: 0)
        var result: Result<(URL, Date), Error>!
        session.dataTask(with: request) { _, response, error in
            defer { completion.signal() }
            if let error { result = .failure(error); return }
            guard let response = response as? HTTPURLResponse, response.statusCode == 302,
                  let location = response.value(forHTTPHeaderField: "Location"),
                  let components = URLComponents(string: location), components.scheme == "https",
                  components.host == "release-assets.githubusercontent.com", components.user == nil, components.password == nil,
                  let url = components.url, let expiration = try? shelfDownloadExpiration(url) else {
                result = .failure(CommandError(message: "GitHub did not return a supported temporary HTTPS download link."))
                return
            }
            result = .success((url, expiration))
        }.resume()
        completion.wait()
        return try result.get()
    }

    func refresh() throws -> ShelfCatalog {
        let (release, previous) = try catalog()
        // Pruning before uploading keeps a full release from blocking its own cleanup.
        for asset in staleShelfAssets(release.assets, active: previous.linkedAssetIDs) {
            try github.call(["api", "--method", "DELETE", "repos/\(Self.repository)/releases/assets/\(asset.id)"])
        }
        // Only older clients use these links, and they see only the apps the release body still lists.
        let listed = Set(try catalogBody(release).applications.map(\.packageAssetID))
        var updated = previous
        var changed = false
        for index in updated.applications.indices where listed.contains(updated.applications[index].packageAssetID) {
            let application = updated.applications[index]
            guard application.profileExpiration > Date().addingTimeInterval(86400) else {
                changed = changed || application.manifestAssetID != nil || application.installExpiration != nil
                updated.applications[index].manifestAssetID = nil
                updated.applications[index].installExpiration = nil
                continue
            }
            if let expiration = application.installExpiration, expiration > Date().addingTimeInterval(120) { continue }
            let (url, expiration) = try downloadLink(assetID: application.packageAssetID)
            guard expiration > Date().addingTimeInterval(120) else {
                throw CommandError(message: "GitHub returned a nearly expired package URL. The existing catalog was preserved; retry shortly.")
            }
            let manifest: [String: Any] = ["items": [["assets": [["kind": "software-package", "url": url.absoluteString]], "metadata": ["bundle-identifier": application.bundleIdentifier, "bundle-version": application.build, "kind": "software", "title": application.name]]]]
            let temporary = files.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).plist")
            defer { try? files.removeItem(at: temporary) }
            try PropertyListSerialization.data(fromPropertyList: manifest, format: .xml, options: 0).write(to: temporary, options: .atomic)
            let asset = try upload(temporary, name: "\(application.bundleIdentifier)-\(application.build)-\(Int(Date().timeIntervalSince1970)).plist", contentType: "application/xml", releaseID: release.id)
            updated.applications[index].manifestAssetID = asset.id
            updated.applications[index].installExpiration = expiration
            changed = true
        }
        if changed { try save(updated, release: release) }
        try publishShelfNotifications(updated)
        return updated
    }
}

// Legacy manifests embed GitHub package links that expire within minutes, so superseded ones are dead soon after
// upload. Clients download the catalog asset right after reading the body that names it, so only the one replaced
// last can still be on its way. The count cap keeps GitHub's 1,000-asset release limit out of reach however many apps
// the shelf holds.
func staleShelfAssets(_ assets: [ShelfAsset], active: Set<Int>, now: Date = Date()) -> [ShelfAsset] {
    let formatter = ISO8601DateFormatter()
    let superseded = assets.filter { !active.contains($0.id) }.sorted { $0.created_at > $1.created_at }
    let replacedCatalog = superseded.first { $0.name.hasPrefix("catalog-") }
    return superseded.enumerated().filter { index, asset in
        asset.id != replacedCatalog?.id && (index >= 300 || formatter.date(from: asset.created_at).map { $0 < now.addingTimeInterval(-900) } == true)
    }.map(\.element)
}

func withShelfLock<T>(_ operation: () throws -> T) throws -> T {
    let path = TestFlightConfiguration.directory.appendingPathComponent("shelf.lock")
    let descriptor = open(path.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { throw CommandError(message: "Cannot open shelf lock.") }
    defer { close(descriptor) }
    let deadline = Date().addingTimeInterval(180)
    while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
        guard errno == EWOULDBLOCK, Date() < deadline else {
            throw CommandError(message: "Another shelf catalog update is still running. Retry shortly.")
        }
        Thread.sleep(forTimeInterval: 0.2)
    }
    return try operation()
}

func refreshShelf() throws {
    let store = try ShelfStore()
    let catalog = try withShelfLock { try store.refresh() }
    try emit(["result": "shelf-links-refreshed", "apps": String(catalog.applications.count)])
    resumeShelfShare(catalog)
    installShelfApplications(catalog, store: store)
}

func setupShelfRefresh() throws {
    _ = try ShelfStore().catalog()
    try installLaunchAgent(identifier: "com.lucaswkuipers.app-shelf-links", command: "refresh-shelf", interval: 60, log: "shelf-refresh")
    try emit(["result": "shelf-refresh-ready", "intervalSeconds": "60"])
}

func installLaunchAgent(identifier: String, command: String, interval: Int, log: String) throws {
    let directory = files.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")
    let logs = files.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/uikit-app")
    try files.createDirectory(at: directory, withIntermediateDirectories: true)
    try files.createDirectory(at: logs, withIntermediateDirectories: true)
    let path = directory.appendingPathComponent("\(identifier).plist")
    let executable = files.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/uikit-app").path
    let properties: [String: Any] = ["Label": identifier, "ProgramArguments": [executable, command], "StartInterval": interval, "RunAtLoad": true, "ProcessType": "Standard", "StandardOutPath": logs.appendingPathComponent("\(log).log").path, "StandardErrorPath": logs.appendingPathComponent("\(log)-error.log").path]
    try PropertyListSerialization.data(fromPropertyList: properties, format: .xml, options: 0).write(to: path, options: .atomic)
    let domain = "gui/\(getuid())"
    _ = try? run("/bin/launchctl", ["bootout", "\(domain)/\(identifier)"], log: nil)
    for attempt in 0..<10 {
        do {
            try run("/bin/launchctl", ["bootstrap", domain, path.path], log: nil)
            return
        } catch {
            if attempt == 9 { throw error }
            Thread.sleep(forTimeInterval: 1)
        }
    }
}

func deliverDirect(directory: String, metadataPath: String = Project.defaultPath) throws {
    let root = URL(fileURLWithPath: directory).standardizedFileURL.resolvingSymlinksInPath()
    let metadata = try Project.load(root: root, path: metadataPath)
    try validate(metadata.bundleIdentifier, pattern: "^com\\.lucaswkuipers\\.[A-Za-z0-9-]+(?:\\.[A-Za-z0-9-]+)*$", label: "personal bundle identifier")
    let lockDirectory = TestFlightConfiguration.directory.appendingPathComponent("locks")
    try files.createDirectory(at: lockDirectory, withIntermediateDirectories: true)
    let descriptor = open(lockDirectory.appendingPathComponent("\(metadata.bundleIdentifier).lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { throw CommandError(message: "Cannot open delivery lock.") }
    defer { close(descriptor) }
    let lockDeadline = Date().addingTimeInterval(900)
    while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
        guard errno == EWOULDBLOCK, Date() < lockDeadline else {
            throw CommandError(message: "Another delivery of this app has been running for over 15 minutes; retry once it finishes.")
        }
        Thread.sleep(forTimeInterval: 2)
    }
    guard metadata.ownerOnly != true || metadata.shelfPlatforms == [.iOS] else {
        throw CommandError(message: "Owner-only shelf apps are iOS only.")
    }
    let store = try ShelfStore()
    let devices = try ShelfDevices.load(for: metadata)
    _ = try store.github.repository(name: metadata.name)
    try verifyPersonalRemote(store.github.git(root, ["remote", "get-url", "origin"], remote: false), name: metadata.name)
    guard try store.github.git(root, ["status", "--porcelain"], remote: false).isEmpty else {
        throw CommandError(message: "Commit app changes before direct delivery.")
    }
    for platform in metadata.shelfPlatforms {
        try deliverDirect(root: root, metadata: metadata, metadataPath: metadataPath, platform: platform, store: store, devices: devices)
    }
}

func deliverDirect(root: URL, metadata: Project, metadataPath: String, platform: ShelfPlatform, store: ShelfStore, devices: ShelfDevices) throws {
    let commit = try store.github.git(root, ["rev-parse", "HEAD"], remote: false)
    let (_, previous) = try store.catalog()
    let previousApplication = previous.applications(for: metadata, platform: platform).first(where: { $0.bundleIdentifier == metadata.bundleIdentifier })
    if let application = previousApplication, application.sourceCommit == commit, application.profileExpiration > Date().addingTimeInterval(86400), devices.isCurrent(application) {
        _ = try withShelfLock { try store.refresh() }
        try emit(["result": "available-in-shelf", "app": metadata.name, "platform": platform.rawValue, "build": application.build, "team": TestFlightConfiguration.personalTeam, "sourcesChanged": "false"])
        return
    }
    let client = try AppStoreClient(configuration: TestFlightConfiguration.load())
    try client.verifyPersonalAccount()
    let apps = try client.list("/v1/apps", query: ["filter[bundleId]": metadata.bundleIdentifier])
    var minimum = try nextBuildNumber(previousApplication?.build)
    if let app = apps.first {
        let flight = try nextAppleBuildNumber(appID: app.id, client: client)
        if flight.compare(minimum, options: .numeric) == .orderedDescending { minimum = flight }
    }
    // Platforms of one commit share its reserved build number.
    let build = try ShelfDeliveryState.reserve(bundle: metadata.bundleIdentifier, commit: commit, minimum: minimum, directory: TestFlightConfiguration.directory).build
    let package = try packageDirect(directory: root.path, build: build, platform: platform, metadataPath: metadataPath)
    let releaseNotes: [String]?
    if previousApplication?.sourceCommit == commit {
        releaseNotes = previousApplication?.releaseNotes
    } else {
        releaseNotes = try shelfReleaseNotes(github: store.github, name: metadata.name, previous: previousApplication?.sourceCommit, commit: commit)
    }
    let resignedForDevices = previousApplication.map { $0.sourceCommit == commit && !devices.isCurrent($0) } ?? false
    let suffix = platform == .iOS ? "" : "-\(platform.rawValue)"
    let application = try publishShelfArtifact(store: store, tag: "\(metadata.name)\(suffix)-\(build)-\(commit.prefix(12))", title: "\(metadata.name) \(package.version) (\(build))\(platform == .iOS ? "" : " for \(platform.rawValue)")", intent: ["sourceCommit": commit, "bundleIdentifier": metadata.bundleIdentifier, "build": build].merging(platform.catalogValue.map { ["platform": $0] } ?? [:]) { $1 }, package: URL(fileURLWithPath: package.path), assetName: "\(metadata.name).ipa", size: package.size, sha256: package.sha256) { asset in
        ShelfApplication(name: package.name, bundleIdentifier: package.bundleIdentifier, version: package.version, build: package.build, minimumOSVersion: package.minimumOSVersion, profileExpiration: package.profileExpiration, sourceCommit: commit, sha256: package.sha256, size: package.size, packageAssetID: asset.id, publishedAt: Date(), manifestAssetID: nil, installExpiration: nil, iconPNG: try shelfIcon(root: root, metadata: metadata), notificationTitle: previousApplication == nil ? "New app available" : "Update available", deviceSet: package.devices, silent: resignedForDevices, releaseNotes: releaseNotes, platform: platform.catalogValue)
    }
    try withShelfLock {
        let (release, latest) = try store.catalog()
        var updated = latest
        var list = latest.applications(for: metadata, platform: platform)
        let cataloged = list.first(where: { $0.bundleIdentifier == application.bundleIdentifier })
        if let cataloged, cataloged.build.compare(build, options: .numeric) == .orderedDescending {
            throw CommandError(message: "A newer build is already available in the shelf. It was preserved.")
        }
        let currentMain = try store.github.call(["api", "repos/lucaswkuipers/\(metadata.name)/git/ref/heads/main", "--jq", ".object.sha"])
        let resigningCatalogedCommit = cataloged?.sourceCommit == commit
        // Apps published on request build whichever main commit they started from, as main may move during a long build.
        let onRequest = try metadata.publishOnRequest == true && shelfCommit(commit, isAncestorOf: currentMain, name: metadata.name, github: store.github)
        guard currentMain == commit || resigningCatalogedCommit || onRequest else {
            throw CommandError(message: "Main has a newer commit. This build was retained in release history without replacing the current shelf app.")
        }
        list.removeAll { $0.bundleIdentifier == application.bundleIdentifier }
        list.append(application)
        list.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        updated.setApplications(list, for: metadata, platform: platform)
        try store.save(updated, release: release)
        _ = try store.refresh()
    }
    try emit(["result": "available-in-shelf", "app": metadata.name, "platform": platform.rawValue, "build": build, "team": TestFlightConfiguration.personalTeam, "sourcesChanged": String(try sourceFingerprint(root) != package.fingerprint)])
}

func shelfCommit(_ commit: String, isAncestorOf head: String, name: String, github: PersonalGitHub) throws -> Bool {
    let status = try github.call(["api", "repos/lucaswkuipers/\(name)/compare/\(commit)...\(head)", "--jq", ".status"])
    return status == "ahead" || status == "identical"
}

func publishShelfArtifact(store: ShelfStore, tag: String, title: String, intent: [String: String], package: URL, assetName: String, size: Int, sha256: String, describe: (ShelfAsset) throws -> ShelfApplication) throws -> ShelfApplication {
    let output = try store.github.call(["api", "--paginate", "--slurp", "repos/\(ShelfStore.repository)/releases?per_page=100"])
    let releases = try store.decoder.decode([[ShelfRelease]].self, from: Data(output.utf8)).flatMap { $0 }
    let drafted = releases.first { release in
        guard release.draft, let body = release.body,
              let saved = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: String] else {
            return false
        }
        return saved == intent
    }
    let artifactRelease: ShelfRelease
    if let existing = releases.first(where: { $0.tag_name == tag }) ?? drafted {
        artifactRelease = existing
    } else {
        let request = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? files.removeItem(at: request) }
        let body = String(decoding: try JSONSerialization.data(withJSONObject: intent, options: [.sortedKeys]), as: UTF8.self)
        try JSONSerialization.data(withJSONObject: ["tag_name": tag, "name": title, "body": body, "draft": true]).write(to: request, options: .atomic)
        artifactRelease = try store.decoder.decode(ShelfRelease.self, from: Data(store.github.call(["api", "--method", "POST", "repos/\(ShelfStore.repository)/releases", "--input", request.path]).utf8))
    }
    if !artifactRelease.draft {
        guard let body = artifactRelease.body else {
            throw CommandError(message: "Published release has no metadata.")
        }
        let existing = try store.decoder.decode(ShelfApplication.self, from: Data(body.utf8))
        guard existing.sourceCommit == intent["sourceCommit"], existing.bundleIdentifier == intent["bundleIdentifier"], existing.build == intent["build"] else {
            throw CommandError(message: "Published release differs from this package. Immutable assets were preserved.")
        }
        return existing
    }
    for asset in artifactRelease.assets {
        try store.github.call(["api", "--method", "DELETE", "repos/\(ShelfStore.repository)/releases/assets/\(asset.id)"])
    }
    let asset = try store.upload(package, name: assetName, contentType: "application/octet-stream", releaseID: artifactRelease.id)
    guard asset.size == size, asset.digest == "sha256:\(sha256)" else {
        throw CommandError(message: "GitHub's uploaded package size or checksum differs. The release remains a draft.")
    }
    let application = try describe(asset)
    try store.updateBody(application, releaseID: artifactRelease.id)
    let request = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? files.removeItem(at: request) }
    try JSONSerialization.data(withJSONObject: ["tag_name": tag, "draft": false, "make_latest": "false"]).write(to: request, options: .atomic)
    let published = try store.decoder.decode(ShelfRelease.self, from: Data(store.github.call(["api", "--method", "PATCH", "repos/\(ShelfStore.repository)/releases/\(artifactRelease.id)", "--input", request.path]).utf8))
    guard !published.draft, published.tag_name == tag, published.assets.contains(where: { $0.id == asset.id }) else {
        throw CommandError(message: "GitHub did not confirm the complete published release. Retry to reconcile this build.")
    }
    return application
}

func shelfIcon(root: URL, metadata: Project) throws -> String? {
    try shelfIcon(metadata: metadata) { path in
        let file = root.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        guard file.path.hasPrefix(root.path + "/") else {
            throw CommandError(message: "The shelf icon must be inside the app repository.")
        }
        guard files.fileExists(atPath: file.path) else {
            return nil
        }
        return try Data(contentsOf: file)
    }
}

// AppShelf shows icons at up to 80 points on 3x screens, so 256 pixels stay sharp everywhere it draws them. Icon sets
// list every size and appearance in no fixed order; the largest default-appearance image is the sharpest source.
func shelfIcon(metadata: Project, read: (String) throws -> Data?) throws -> String? {
    let path: String
    if let iconImage = metadata.iconImage {
        path = iconImage
    } else {
        let directory = "\(metadata.name)/Assets.xcassets/AppIcon.appiconset"
        guard let contents = try read("\(directory)/Contents.json") else {
            return nil
        }
        struct Contents: Decodable {
            struct Image: Decodable {
                let filename: String?
                let size: String?
                let scale: String?
                let appearances: [[String: String]]?

                var pixels: Double {
                    let points = Double(size?.split(separator: "x").first ?? "") ?? 0
                    let factor = Double(scale?.dropLast() ?? "") ?? 1
                    return points * factor
                }
            }
            let images: [Image]
        }
        let images = try JSONDecoder().decode(Contents.self, from: contents).images.filter { $0.filename != nil && $0.appearances == nil }
        guard let filename = images.max(by: { $0.pixels < $1.pixels })?.filename,
              !filename.contains("/"), !filename.contains("..") else {
            throw CommandError(message: "Cannot read the app icon for the shelf.")
        }
        path = "\(directory)/\(filename)"
    }
    guard let data = try read(path),
          let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 256
          ] as CFDictionary) else {
        throw CommandError(message: "Cannot read the app icon for the shelf.")
    }
    let encoded = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(encoded, "public.png" as CFString, 1, nil) else {
        throw CommandError(message: "Cannot create the shelf icon.")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw CommandError(message: "Cannot encode the shelf icon.") }
    return (encoded as Data).base64EncodedString()
}

// Deliveries make each catalog icon, so this brings apps that have not shipped since a change to icons up to date. It
// reads each app's metadata and icon at its cataloged commit and keeps the existing icon when that is not possible.
func refreshShelfIcons() throws {
    let store = try ShelfStore()
    let (_, catalog) = try store.catalog()
    let icons = try shelfIcons(catalog, store: store)
    try withShelfLock {
        let (release, latest) = try store.catalog()
        let updated = latest.mapApplications { application in
            var application = application
            application.iconPNG = icons[application.packageAssetID] ?? application.iconPNG
            return application
        }
        try store.save(updated, release: release)
        _ = try store.refresh()
    }
    try emit(["result": "shelf-icons-refreshed", "icons": String(icons.count)])
}

func shelfIcons(_ catalog: ShelfCatalog, store: ShelfStore) throws -> [Int: String] {
    struct Release: Decodable {
        struct Asset: Decodable {
            let id: Int
        }
        let tag_name: String
        let assets: [Asset]
    }
    let output = try store.github.call(["api", "--paginate", "--slurp", "repos/\(ShelfStore.repository)/releases?per_page=100"])
    var repositories: [Int: String] = [:]
    for release in try store.decoder.decode([[Release]].self, from: Data(output.utf8)).joined() {
        for asset in release.assets {
            repositories[asset.id] = release.tag_name.components(separatedBy: "-")[0]
        }
    }
    var icons: [Int: String] = [:]
    for application in catalog.applications + (catalog.visionApplications ?? []) + (catalog.ownerApplications ?? []) {
        do {
            guard let repository = repositories[application.packageAssetID] else {
                throw CommandError(message: "its package release is missing")
            }
            func download(_ path: String) throws -> Data {
                guard let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
                    throw CommandError(message: "cannot encode \(path)")
                }
                let location = "repos/lucaswkuipers/\(repository)"
                let sha = try store.github.call(["api", "\(location)/contents/\(encodedPath)?ref=\(application.sourceCommit)", "--jq", ".sha"])
                let content = try store.github.call(["api", "\(location)/git/blobs/\(sha)", "--jq", ".content"])
                guard let data = Data(base64Encoded: content, options: .ignoreUnknownCharacters) else {
                    throw CommandError(message: "GitHub returned an unreadable \(path)")
                }
                return data
            }
            let metadata = try JSONDecoder().decode(Project.self, from: download(Project.defaultPath))
            guard metadata.bundleIdentifier == application.bundleIdentifier else {
                throw CommandError(message: "it is delivered with other metadata in \(repository)")
            }
            guard let icon = try shelfIcon(metadata: metadata, read: { try download($0) }) else {
                throw CommandError(message: "it has no app icon")
            }
            icons[application.packageAssetID] = icon
        } catch {
            status("Kept the catalog icon of \(application.name): \(error.localizedDescription)")
        }
    }
    return icons
}

func shelfReleaseNotes(github: PersonalGitHub, name: String, previous: String?, commit: String) throws -> [String] {
    struct Commit: Decodable {
        struct Details: Decodable {
            let message: String
        }
        let commit: Details
        let parents: [Parent]
        struct Parent: Decodable {
            let sha: String
        }
    }
    struct Comparison: Decodable {
        let status: String
        let commits: [Commit]
    }
    let commits: [Commit]
    if let previous {
        let output = try github.call(["api", "--paginate", "--slurp", "repos/lucaswkuipers/\(name)/compare/\(previous)...\(commit)?per_page=100"])
        let pages = try JSONDecoder().decode([Comparison].self, from: Data(output.utf8))
        guard pages.allSatisfy({ $0.status == "ahead" || $0.status == "identical" }) else {
            throw CommandError(message: "Cannot generate release notes: the published commit is not an ancestor of this build.")
        }
        commits = pages.flatMap(\.commits).reversed()
    } else {
        let output = try github.call(["api", "repos/lucaswkuipers/\(name)/commits?sha=\(commit)&per_page=6"])
        commits = try JSONDecoder().decode([Commit].self, from: Data(output.utf8))
    }
    // The catalog carries these notes, so busy repositories keep only the latest ones.
    return Array(commits.filter { $0.parents.count < 2 }.compactMap { $0.commit.message.split(separator: "\n").first.map(String.init) }
        .filter { !$0.lowercased().contains("[skip ci]") }.prefix(30))
}
