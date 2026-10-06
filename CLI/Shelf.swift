import Foundation

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
}

struct ShelfCatalog: Codable {
    let schema: Int
    var applications: [ShelfApplication]
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
        guard !release.draft, let body = release.body else { throw CommandError(message: "Shelf catalog is unavailable.") }
        let catalog = try decoder.decode(ShelfCatalog.self, from: Data(body.utf8))
        guard catalog.schema == 1 else { throw CommandError(message: "Unsupported shelf catalog version.") }
        return (release, catalog)
    }

    func updateBody<T: Encodable>(_ value: T, releaseID: Int) throws {
        let temporary = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? files.removeItem(at: temporary) }
        let body = String(decoding: try encoder.encode(value), as: UTF8.self)
        try JSONSerialization.data(withJSONObject: ["body": body]).write(to: temporary, options: .atomic)
        try github.call(["api", "--method", "PATCH", "repos/\(Self.repository)/releases/\(releaseID)", "--input", temporary.path])
    }

    func upload(_ file: URL, name: String, contentType: String, releaseID: Int) throws -> ShelfAsset {
        var components = URLComponents(string: "https://uploads.github.com/repos/\(Self.repository)/releases/\(releaseID)/assets")!
        components.queryItems = [URLQueryItem(name: "name", value: name)]
        let output = try github.call(["api", "--method", "POST", components.url!.absoluteString, "-H", "Content-Type: \(contentType)", "--input", file.path])
        return try decoder.decode(ShelfAsset.self, from: Data(output.utf8))
    }

    func downloadLink(assetID: Int) throws -> (URL, Date) {
        try PersonalGitHub.verifyActiveAccount(environment: github.baseEnvironment)
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
        var updated = previous
        var changed = false
        for index in updated.applications.indices {
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
        if changed { try updateBody(updated, releaseID: release.id) }
        let activeIDs = Set(updated.applications.compactMap(\.manifestAssetID))
        for asset in release.assets where !activeIDs.contains(asset.id) {
            guard let created = ISO8601DateFormatter().date(from: asset.created_at), created < Date().addingTimeInterval(-7200) else { continue }
            try github.call(["api", "--method", "DELETE", "repos/\(Self.repository)/releases/assets/\(asset.id)"])
        }
        return updated
    }
}

func withShelfLock<T>(_ operation: () throws -> T) throws -> T {
    let path = TestFlightConfiguration.directory.appendingPathComponent("shelf.lock")
    let descriptor = open(path.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { throw CommandError(message: "Cannot open shelf lock.") }
    defer { close(descriptor) }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
        throw CommandError(message: "Another shelf publish or link refresh is running. Retry shortly.")
    }
    return try operation()
}

func refreshShelf() throws {
    try withShelfLock {
        let catalog = try ShelfStore().refresh()
        try emit(["result": "shelf-links-refreshed", "apps": String(catalog.applications.count)])
    }
}

func setupShelfRefresh() throws {
    _ = try ShelfStore().catalog()
    let directory = files.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")
    let logs = files.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/uikit-app")
    try files.createDirectory(at: directory, withIntermediateDirectories: true)
    try files.createDirectory(at: logs, withIntermediateDirectories: true)
    let identifier = "com.lucaswkuipers.app-shelf-links"
    let path = directory.appendingPathComponent("\(identifier).plist")
    let executable = files.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/uikit-app").path
    let properties: [String: Any] = ["Label": identifier, "ProgramArguments": [executable, "refresh-shelf"], "StartInterval": 60, "RunAtLoad": true, "ProcessType": "Background", "StandardOutPath": logs.appendingPathComponent("shelf-refresh.log").path, "StandardErrorPath": logs.appendingPathComponent("shelf-refresh-error.log").path]
    try PropertyListSerialization.data(fromPropertyList: properties, format: .xml, options: 0).write(to: path, options: .atomic)
    let domain = "gui/\(getuid())"
    _ = try? run("/bin/launchctl", ["bootout", "\(domain)/\(identifier)"], log: nil)
    for attempt in 0..<10 {
        do {
            try run("/bin/launchctl", ["bootstrap", domain, path.path], log: nil)
            try emit(["result": "shelf-refresh-ready", "intervalSeconds": "60"])
            return
        } catch {
            if attempt == 9 { throw error }
            Thread.sleep(forTimeInterval: 1)
        }
    }
}

func deliverDirect(directory: String) throws {
    let root = URL(fileURLWithPath: directory).standardizedFileURL.resolvingSymlinksInPath()
    let metadata = try JSONDecoder().decode(Project.self, from: Data(contentsOf: root.appendingPathComponent(".uikit-app.json")))
    let store = try ShelfStore()
    _ = try store.github.repository(name: metadata.name)
    try verifyPersonalRemote(store.github.git(root, ["remote", "get-url", "origin"], remote: false), name: metadata.name)
    guard try store.github.git(root, ["status", "--porcelain"], remote: false).isEmpty else {
        throw CommandError(message: "Commit app changes before direct delivery.")
    }
    let commit = try store.github.git(root, ["rev-parse", "HEAD"], remote: false)
    try withShelfLock {
        let (release, previous) = try store.catalog()
        if let application = previous.applications.first(where: { $0.bundleIdentifier == metadata.bundleIdentifier && $0.sourceCommit == commit }), application.profileExpiration > Date().addingTimeInterval(86400) {
            _ = try store.refresh()
            try emit(["result": "available-in-shelf", "app": metadata.name, "build": application.build, "team": TestFlightConfiguration.personalTeam, "sourcesChanged": "false"])
            return
        }
        let previousBuild = previous.applications.first(where: { $0.bundleIdentifier == metadata.bundleIdentifier })?.build
        let client = try AppStoreClient(configuration: TestFlightConfiguration.load())
        try client.verifyPersonalAccount()
        let apps = try client.list("/v1/apps", query: ["filter[bundleId]": metadata.bundleIdentifier])
        var build = try nextBuildNumber(previousBuild)
        if let app = apps.first {
            let flight = try newDelivery(fingerprint: "", appID: app.id, bundle: metadata.bundleIdentifier, cache: files.temporaryDirectory, client: client)
            if flight.buildNumber.compare(build, options: .numeric) == .orderedDescending { build = flight.buildNumber }
        }
        let package = try packageDirect(directory: directory, build: build)
        let tag = "\(metadata.name)-\(build)-\(commit.prefix(12))"
        let releasesOutput = try store.github.call(["api", "--paginate", "--slurp", "repos/\(ShelfStore.repository)/releases?per_page=100"])
        let releases = try store.decoder.decode([[ShelfRelease]].self, from: Data(releasesOutput.utf8)).flatMap { $0 }
        var artifactRelease: ShelfRelease
        if let existing = releases.first(where: { $0.tag_name == tag }) {
            artifactRelease = existing
        } else {
            try store.github.call(["release", "create", tag, "--repo", ShelfStore.repository, "--draft", "--title", "\(metadata.name) \(package.version) (\(build))", "--notes", "Preparing signed personal app"])
            let output = try store.github.call(["api", "repos/\(ShelfStore.repository)/releases/tags/\(tag)"])
            artifactRelease = try store.decoder.decode(ShelfRelease.self, from: Data(output.utf8))
        }
        let application: ShelfApplication
        if !artifactRelease.draft {
            guard let body = artifactRelease.body else { throw CommandError(message: "Published release has no metadata.") }
            let existing = try store.decoder.decode(ShelfApplication.self, from: Data(body.utf8))
            guard existing.sourceCommit == commit, existing.bundleIdentifier == metadata.bundleIdentifier, existing.build == build else {
                throw CommandError(message: "Published release differs from this package. Immutable assets were preserved.")
            }
            application = existing
        } else {
            for asset in artifactRelease.assets {
                try store.github.call(["api", "--method", "DELETE", "repos/\(ShelfStore.repository)/releases/assets/\(asset.id)"])
            }
            let asset = try store.upload(URL(fileURLWithPath: package.path), name: "\(metadata.name).ipa", contentType: "application/octet-stream", releaseID: artifactRelease.id)
            guard asset.size == package.size, asset.digest == "sha256:\(package.sha256)" else {
                throw CommandError(message: "GitHub's uploaded package size or checksum differs. The release remains a draft.")
            }
            application = ShelfApplication(name: package.name, bundleIdentifier: package.bundleIdentifier, version: package.version, build: package.build, minimumOSVersion: package.minimumOSVersion, profileExpiration: package.profileExpiration, sourceCommit: commit, sha256: package.sha256, size: package.size, packageAssetID: asset.id, publishedAt: Date(), manifestAssetID: nil, installExpiration: nil)
            try store.updateBody(application, releaseID: artifactRelease.id)
            try store.github.call(["release", "edit", tag, "--repo", ShelfStore.repository, "--draft=false", "--latest=false"])
        }
        var updated = previous
        let currentMain = try store.github.call(["api", "repos/lucaswkuipers/\(metadata.name)/git/ref/heads/main", "--jq", ".object.sha"])
        guard currentMain == commit else {
            throw CommandError(message: "Main has a newer commit. This build was retained in release history without replacing the current shelf app.")
        }
        updated.applications.removeAll { $0.bundleIdentifier == application.bundleIdentifier }
        updated.applications.append(application)
        updated.applications.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        try store.updateBody(updated, releaseID: release.id)
        _ = try store.refresh()
        try emit(["result": "available-in-shelf", "app": metadata.name, "build": build, "team": TestFlightConfiguration.personalTeam, "sourcesChanged": String(try sourceFingerprint(root) != package.fingerprint)])
    }
}
