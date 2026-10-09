import CryptoKit
import Foundation

struct ShelfInstallConfiguration: Codable {
    static let path = TestFlightConfiguration.directory.appendingPathComponent("shelf-installs.json")

    let deviceUDID: String

    static func load() throws -> Self? {
        guard files.fileExists(atPath: path.path) else {
            return nil
        }
        let configuration = try JSONDecoder().decode(Self.self, from: Data(contentsOf: path))
        guard configuration.deviceUDID == (try DirectConfiguration.load()).deviceUDID else {
            throw CommandError(message: "Shelf installs must target the configured personal iPhone. Run setup-shelf-installs again after changing devices.")
        }
        return configuration
    }
}

struct ShelfInstalledApps: Decodable {
    struct Application: Decodable {
        let bundleIdentifier: String
        let version: String?
        let bundleVersion: String?
        let appClip: Bool
    }

    struct Result: Decodable {
        let apps: [Application]
    }

    let result: Result

    func needsInstall(_ application: ShelfApplication) throws -> Bool {
        let matches = result.apps.filter { $0.bundleIdentifier == application.bundleIdentifier && !$0.appClip }
        guard !matches.isEmpty else {
            return true
        }
        guard matches.count == 1, let installed = matches.first,
              let version = installed.version, let build = installed.bundleVersion else {
            throw CommandError(message: "Cannot determine the installed version of \(application.name).")
        }
        try validate(version, pattern: "^[0-9]+(?:\\.[0-9]+)*$", label: "installed version")
        try validate(build, pattern: "^[0-9]+(?:\\.[0-9]+)*$", label: "installed build")
        let comparison = version.compare(application.version, options: .numeric)
        return comparison == .orderedAscending || (comparison == .orderedSame && build.compare(application.build, options: .numeric) == .orderedAscending)
    }
}

func shelfInstalledApps(deviceUDID: String) throws -> ShelfInstalledApps {
    let output = try run("/usr/bin/xcrun", ["devicectl", "device", "info", "apps", "--device", deviceUDID,
        "--include-all-apps", "--filter", "bundleIdentifier BEGINSWITH 'com.lucaswkuipers.'",
        "--timeout", "15", "--quiet", "--json-output", "-"], log: nil, separateError: true)
    return try JSONDecoder().decode(ShelfInstalledApps.self, from: Data(output.utf8))
}

func verifyShelfPackage(_ path: URL, application: ShelfApplication) throws {
    let data = try Data(contentsOf: path, options: .mappedIfSafe)
    let checksum = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    guard data.count == application.size, checksum == application.sha256 else {
        throw CommandError(message: "Package size or checksum differs from the shelf catalog for \(application.name).")
    }
}

func shelfInstallPackage(_ application: ShelfApplication, store: ShelfStore, cache: URL) throws -> URL {
    let path = cache.appendingPathComponent("\(application.sha256).ipa")
    if files.fileExists(atPath: path.path) {
        do {
            try verifyShelfPackage(path, application: application)
            return path
        } catch {
            try files.removeItem(at: path)
        }
    }
    let directCache = files.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/uikit-app/Direct")
    if let directories = files.enumerator(at: directCache, includingPropertiesForKeys: nil) {
        for case let directory as URL in directories where directories.level == 3 {
            directories.skipDescendants()
            let record = directory.appendingPathComponent("package.json")
            guard let data = try? Data(contentsOf: record),
                  let package = try? JSONDecoder().decode(DirectPackage.self, from: data),
                  package.sha256 == application.sha256,
                  package.bundleIdentifier == application.bundleIdentifier else {
                continue
            }
            let source = URL(fileURLWithPath: package.path)
            guard (try? verifyShelfPackage(source, application: application)) != nil else {
                continue
            }
            try files.copyItem(at: source, to: path)
            return path
        }
    }
    let (url, expiration) = try store.downloadLink(assetID: application.packageAssetID)
    guard expiration > Date().addingTimeInterval(60) else {
        throw CommandError(message: "Package link expires too soon. The next shelf refresh will retry.")
    }
    let temporary = cache.appendingPathComponent("\(UUID().uuidString).download")
    defer { try? files.removeItem(at: temporary) }
    try run("/usr/bin/curl", ["--fail", "--silent", "--show-error", "--connect-timeout", "15", "--max-time", "120",
        "--output", temporary.path, url.absoluteString], log: nil)
    try verifyShelfPackage(temporary, application: application)
    try files.moveItem(at: temporary, to: path)
    return path
}

func verifyShelfInstall(_ path: URL, application: ShelfApplication, deviceUDID: String) throws {
    let information = try PropertyListSerialization.propertyList(from: Data(contentsOf: path.appendingPathComponent("Info.plist")), format: nil) as? [String: Any]
    guard information?["CFBundleIdentifier"] as? String == application.bundleIdentifier,
          information?["CFBundleShortVersionString"] as? String == application.version,
          information?["CFBundleVersion"] as? String == application.build else {
        throw CommandError(message: "Package identity does not match the shelf catalog for \(application.name).")
    }
    try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", path.path], log: nil)
    let signature = try run("/usr/bin/codesign", ["-dvv", path.path], log: nil)
    guard signature.split(separator: "\n").contains("TeamIdentifier=\(TestFlightConfiguration.personalTeam)") else {
        throw CommandError(message: "Shelf package has the wrong signing team.")
    }
    let decoded = try run("/usr/bin/security", ["cms", "-D", "-i", path.appendingPathComponent("embedded.mobileprovision").path], log: nil, separateError: true)
    guard let profile = try PropertyListSerialization.propertyList(from: Data(decoded.utf8), format: nil) as? [String: Any] else {
        throw CommandError(message: "Cannot read the shelf package's provisioning profile.")
    }
    _ = try verifyDirectProfile(profile, bundle: application.bundleIdentifier, deviceUDID: deviceUDID)
}

func installShelfApplications(_ catalog: ShelfCatalog, store: ShelfStore) {
    do {
        guard let configuration = try ShelfInstallConfiguration.load() else {
            return
        }
        let descriptor = open(TestFlightConfiguration.directory.appendingPathComponent("shelf-installs.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw CommandError(message: "Cannot open shelf installation lock.")
        }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            return
        }
        var installed = try shelfInstalledApps(deviceUDID: configuration.deviceUDID)
        let cache = files.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/uikit-app/ShelfInstalls")
        try files.createDirectory(at: cache, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let activePackages = Set(catalog.applications.map { "\($0.sha256).ipa" })
        for path in try files.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil) where path.pathExtension == "ipa" && !activePackages.contains(path.lastPathComponent) {
            try files.removeItem(at: path)
        }
        for application in catalog.applications {
            do {
                try validate(application.bundleIdentifier, pattern: "^com\\.lucaswkuipers\\.[A-Za-z0-9-]+(?:\\.[A-Za-z0-9-]+)*$", label: "personal bundle identifier")
                try validate(application.sha256, pattern: "^[0-9a-f]{64}$", label: "package checksum")
                try validate(application.version, pattern: "^[0-9]+(?:\\.[0-9]+)*$", label: "catalog version")
                try validate(application.build, pattern: "^[0-9]+(?:\\.[0-9]+)*$", label: "catalog build")
                guard application.profileExpiration > Date().addingTimeInterval(86400), try installed.needsInstall(application) else {
                    continue
                }
                let package = try shelfInstallPackage(application, store: store, cache: cache)
                let unpacked = cache.appendingPathComponent(UUID().uuidString)
                defer { try? files.removeItem(at: unpacked) }
                try run("/usr/bin/ditto", ["-x", "-k", package.path, unpacked.path], log: nil)
                let applications = try files.contentsOfDirectory(at: unpacked.appendingPathComponent("Payload"), includingPropertiesForKeys: nil).filter { $0.pathExtension == "app" }
                guard applications.count == 1, let path = applications.first else {
                    throw CommandError(message: "Expected one application in the shelf package.")
                }
                try verifyShelfInstall(path, application: application, deviceUDID: configuration.deviceUDID)
                installed = try shelfInstalledApps(deviceUDID: configuration.deviceUDID)
                guard try installed.needsInstall(application) else {
                    continue
                }
                status("Installing \(application.name) build \(application.build) on the personal iPhone…")
                try run("/usr/bin/xcrun", ["devicectl", "device", "install", "app", "--device", configuration.deviceUDID, path.path, "--timeout", "120", "--quiet"], log: nil)
                installed = try shelfInstalledApps(deviceUDID: configuration.deviceUDID)
                guard installed.result.apps.contains(where: { $0.bundleIdentifier == application.bundleIdentifier && !$0.appClip && $0.version == application.version && $0.bundleVersion == application.build }) else {
                    throw CommandError(message: "The iPhone has not confirmed \(application.name) build \(application.build). The next refresh will check again.")
                }
                try emit(["result": "installed-on-device", "app": application.name, "build": application.build, "device": configuration.deviceUDID, "launched": "false"])
            } catch {
                status("Shelf installation pending for \(application.name): \(error.localizedDescription)")
            }
        }
    } catch {
        status("Mac-assisted shelf installs deferred until a later refresh: \(error.localizedDescription)")
    }
}

func setupShelfInstalls() throws {
    let configuration = ShelfInstallConfiguration(deviceUDID: try DirectConfiguration.load().deviceUDID)
    try setupShelfRefresh()
    try JSONEncoder().encode(configuration).write(to: ShelfInstallConfiguration.path, options: .atomic)
    try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ShelfInstallConfiguration.path.path)
    try emit(["result": "shelf-installs-enabled", "device": configuration.deviceUDID, "intervalSeconds": "60", "launchApps": "false"])
}
