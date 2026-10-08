import CryptoKit
import Foundation

struct DirectConfiguration: Codable {
    let certificateID: String
    let certificateSHA1: String
    let deviceID: String
    let deviceUDID: String

    static let path = TestFlightConfiguration.directory.appendingPathComponent("direct.json")

    static func load() throws -> Self {
        guard files.fileExists(atPath: path.path) else {
            throw RequiredAction(result: "needs-direct-setup", message: "Configure the personal iPhone for direct distribution first.", command: "uikit-app setup-direct --device <UDID> --name <device-name>")
        }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: path))
    }
}

func setupDirect(options: Options) throws {
    guard let deviceUDID = options.values["--device"], let deviceName = options.values["--name"], !deviceName.isEmpty else {
        throw CommandError(message: "Required: --device <UDID> --name <device-name>")
    }
    try validate(deviceUDID, pattern: "^[A-Fa-f0-9-]{25,40}$", label: "device UDID")
    let client = try AppStoreClient(configuration: TestFlightConfiguration.load())
    try client.verifyPersonalAccount()
    let matches = try client.list("/v1/devices", query: ["filter[udid]": deviceUDID])
    let device: AppleResource
    if let existing = matches.first {
        guard existing.string("status") == "ENABLED", existing.string("platform") == "IOS" else {
            throw CommandError(message: "The selected personal iPhone must be enabled for iOS development.")
        }
        device = existing
    } else {
        device = try client.create(type: "devices", attributes: ["name": deviceName, "udid": deviceUDID, "platform": "IOS"], relationships: [:])
    }
    let directory = TestFlightConfiguration.directory.appendingPathComponent("direct-signing")
    try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let key = directory.appendingPathComponent("distribution.key")
    let request = directory.appendingPathComponent("distribution.csr")
    let certificateFile = directory.appendingPathComponent("distribution.cer")
    let previousMask = umask(0o077)
    defer { umask(previousMask) }
    if let saved = try? DirectConfiguration.load() {
        let certificate = try client.item("/v1/certificates/\(saved.certificateID)")
        guard certificate.string("certificateType") == "DISTRIBUTION",
              try run("/usr/bin/security", ["find-identity", "-v", "-p", "codesigning"], log: nil).contains(saved.certificateSHA1) else {
            throw CommandError(message: "The saved personal distribution identity is missing or expired. Repair it before changing direct-distribution settings.")
        }
        let updated = DirectConfiguration(certificateID: saved.certificateID, certificateSHA1: saved.certificateSHA1, deviceID: device.id, deviceUDID: deviceUDID)
        try JSONEncoder().encode(updated).write(to: DirectConfiguration.path, options: .atomic)
        try emit(["result": "personal-direct-signing-ready", "team": TestFlightConfiguration.personalTeam, "device": deviceName])
        return
    }
    if !files.fileExists(atPath: request.path) {
        try run("/usr/bin/openssl", ["req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", key.path, "-out", request.path, "-subj", "/CN=UIKit App Personal Distribution"], log: nil)
    }
    let publicKey = try run("/usr/bin/openssl", ["req", "-in", request.path, "-pubkey", "-noout"], log: nil)
    let certificates = try client.list("/v1/certificates", query: ["filter[certificateType]": "DISTRIBUTION"])
    var selected: AppleResource?
    for certificate in certificates {
        guard let content = certificate.string("certificateContent"), let data = Data(base64Encoded: content) else {
            continue
        }
        try data.write(to: certificateFile, options: .atomic)
        let candidate = try run("/usr/bin/openssl", ["x509", "-inform", "DER", "-in", certificateFile.path, "-pubkey", "-noout"], log: nil)
        if candidate == publicKey {
            selected = certificate
            break
        }
    }
    if selected == nil {
        selected = try client.create(type: "certificates", attributes: ["certificateType": "DISTRIBUTION", "csrContent": String(contentsOf: request, encoding: .utf8)], relationships: [:])
    }
    guard let certificate = selected, let content = certificate.string("certificateContent"), let certificateData = Data(base64Encoded: content) else {
        throw CommandError(message: "Apple did not return the personal distribution certificate.")
    }
    try certificateData.write(to: certificateFile, options: .atomic)
    let subject = try run("/usr/bin/openssl", ["x509", "-inform", "DER", "-in", certificateFile.path, "-noout", "-subject", "-nameopt", "RFC2253"], log: nil)
    guard subject.contains("OU=\(TestFlightConfiguration.personalTeam)") else {
        throw CommandError(message: "Distribution certificate is not from the personal team.")
    }
    let certificatePEM = directory.appendingPathComponent("distribution.pem")
    let bundle = directory.appendingPathComponent("distribution.p12")
    let password = try run("/usr/bin/openssl", ["rand", "-hex", "32"], log: nil)
    let passwordFile = directory.appendingPathComponent("import-password")
    try password.write(to: passwordFile, atomically: true, encoding: .utf8)
    defer {
        try? files.removeItem(at: passwordFile)
        try? files.removeItem(at: bundle)
    }
    try run("/usr/bin/openssl", ["x509", "-inform", "DER", "-in", certificateFile.path, "-out", certificatePEM.path], log: nil)
    try run("/usr/bin/openssl", ["pkcs12", "-export", "-inkey", key.path, "-in", certificatePEM.path, "-out", bundle.path, "-passout", "file:\(passwordFile.path)"], log: nil)
    let keychain = files.homeDirectoryForCurrentUser.appendingPathComponent("Library/Keychains/login.keychain-db")
    try run("/usr/bin/security", ["import", bundle.path, "-k", keychain.path, "-P", password, "-T", "/usr/bin/codesign"], log: nil)
    let hash = Insecure.SHA1.hash(data: certificateData).map { String(format: "%02X", $0) }.joined()
    guard try run("/usr/bin/security", ["find-identity", "-v", "-p", "codesigning"], log: nil).contains(hash) else {
        throw CommandError(message: "Imported distribution identity could not be verified.")
    }
    let saved = DirectConfiguration(certificateID: certificate.id, certificateSHA1: hash, deviceID: device.id, deviceUDID: deviceUDID)
    try JSONEncoder().encode(saved).write(to: DirectConfiguration.path, options: .atomic)
    try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: DirectConfiguration.path.path)
    try emit(["result": "personal-direct-signing-ready", "team": TestFlightConfiguration.personalTeam, "device": deviceName])
}

func verifyDirectProfile(_ profile: [String: Any], bundle: String, deviceUDID: String) throws -> Date {
    guard profile["TeamIdentifier"] as? [String] == [TestFlightConfiguration.personalTeam],
          profile["ProvisionedDevices"] as? [String] == [deviceUDID],
          profile["ProvisionsAllDevices"] as? Bool != true,
          let entitlements = profile["Entitlements"] as? [String: Any],
          entitlements["application-identifier"] as? String == "\(TestFlightConfiguration.personalTeam).\(bundle)",
          entitlements["get-task-allow"] as? Bool == false,
          let expiration = profile["ExpirationDate"] as? Date, expiration > Date().addingTimeInterval(86400) else {
        throw CommandError(message: "Direct distribution requires an unexpired personal Ad Hoc profile containing only the configured iPhone.")
    }
    return expiration
}

func directProfile(client: AppStoreClient, configuration: DirectConfiguration, metadata: Project, cache: URL, capabilityRevision: String) throws -> String {
    let bundles = try client.list("/v1/bundleIds", query: ["filter[identifier]": metadata.bundleIdentifier])
    let bundle: AppleResource
    if let existing = bundles.first {
        guard existing.string("seedId") == TestFlightConfiguration.personalTeam else {
            throw CommandError(message: "Bundle identifier belongs to another team.")
        }
        bundle = existing
    } else {
        bundle = try client.create(type: "bundleIds", attributes: ["identifier": metadata.bundleIdentifier, "name": metadata.name, "platform": "IOS"], relationships: [:])
    }
    let profileName = "UIKit App \(metadata.bundleIdentifier) \(configuration.deviceID) \(configuration.certificateID)\(capabilityRevision)"
    let profiles = try client.list("/v1/profiles", query: ["filter[name]": profileName, "filter[profileType]": "IOS_APP_ADHOC", "filter[profileState]": "ACTIVE"])
    let profile: AppleResource
    if let existing = profiles.first {
        profile = existing
    } else {
        profile = try client.create(type: "profiles", attributes: ["name": profileName, "profileType": "IOS_APP_ADHOC"], relationships: [
            "bundleId": ["data": ["type": "bundleIds", "id": bundle.id]],
            "certificates": ["data": [["type": "certificates", "id": configuration.certificateID]]],
            "devices": ["data": [["type": "devices", "id": configuration.deviceID]]]
        ])
    }
    guard let content = profile.string("profileContent"), let data = Data(base64Encoded: content) else {
        throw CommandError(message: "Apple did not return the direct-distribution profile.")
    }
    let downloaded = cache.appendingPathComponent("Direct.mobileprovision")
    try data.write(to: downloaded, options: .atomic)
    let decoded = try run("/usr/bin/security", ["cms", "-D", "-i", downloaded.path], log: nil, separateError: true)
    guard let values = try PropertyListSerialization.propertyList(from: Data(decoded.utf8), format: nil) as? [String: Any], let uuid = values["UUID"] as? String else {
        throw CommandError(message: "Cannot decode the direct-distribution profile.")
    }
    _ = try verifyDirectProfile(values, bundle: metadata.bundleIdentifier, deviceUDID: configuration.deviceUDID)
    let installed = files.homeDirectoryForCurrentUser.appendingPathComponent("Library/Developer/Xcode/UserData/Provisioning Profiles")
    try files.createDirectory(at: installed, withIntermediateDirectories: true)
    try data.write(to: installed.appendingPathComponent("\(uuid).mobileprovision"), options: .atomic)
    return uuid
}

struct DirectPackage: Codable {
    let name: String
    let bundleIdentifier: String
    let version: String
    let build: String
    let minimumOSVersion: String
    let profileExpiration: Date
    let fingerprint: String
    let path: String
    let sha256: String
    let size: Int
}

func packageDirect(directory: String, build: String) throws -> DirectPackage {
    _ = try nextBuildNumber(build)
    let root = URL(fileURLWithPath: directory).standardizedFileURL.resolvingSymlinksInPath()
    let metadata = try JSONDecoder().decode(Project.self, from: Data(contentsOf: root.appendingPathComponent(".uikit-app.json")))
    try validate(metadata.name, pattern: "^[A-Za-z][A-Za-z0-9]*$", label: "project name")
    guard metadata.bundleIdentifier.hasPrefix(TestFlightConfiguration.bundlePrefix) else {
        throw CommandError(message: "Direct distribution is restricted to personal apps.")
    }
    let configuration = try DirectConfiguration.load()
    let client = try AppStoreClient(configuration: TestFlightConfiguration.load())
    try client.verifyPersonalAccount()
    let fingerprint = try sourceFingerprint(root)
    let cache = files.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/uikit-app/Direct/\(metadata.name)/\(configuration.certificateID)-\(configuration.deviceID)/\(fingerprint.prefix(16))-\(build)")
    try files.createDirectory(at: cache, withIntermediateDirectories: true)
    let descriptor = open(cache.appendingPathComponent("package.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { throw CommandError(message: "Cannot open package lock.") }
    defer { close(descriptor) }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw CommandError(message: "This package is already building.") }
    let state = cache.appendingPathComponent("package.json")
    if let data = try? Data(contentsOf: state), let saved = try? JSONDecoder().decode(DirectPackage.self, from: data),
       saved.fingerprint == fingerprint, saved.profileExpiration > Date().addingTimeInterval(86400),
       let package = try? Data(contentsOf: URL(fileURLWithPath: saved.path), options: .mappedIfSafe),
       SHA256.hash(data: package).map({ String(format: "%02x", $0) }).joined() == saved.sha256 {
        return saved
    }
    let projectArguments = ["-project", root.appendingPathComponent("\(metadata.name).xcodeproj").path, "-scheme", metadata.name, "-configuration", "Release"]
    let settingsJSON = try run("/usr/bin/xcodebuild", projectArguments + ["-destination", "generic/platform=iOS", "-showBuildSettings", "-json"], log: nil, separateError: true)
    guard let targets = try JSONSerialization.jsonObject(with: Data(settingsJSON.utf8)) as? [[String: Any]], targets.count == 1,
          let settings = targets.first?["buildSettings"] as? [String: Any] else {
        throw CommandError(message: "Direct packaging currently requires one application target; extension profiles need explicit support.")
    }
    try verifyPersonalSettings(settings, expectedBundle: metadata.bundleIdentifier)
    var entitlements: [String: Any] = [:]
    if let path = settings["CODE_SIGN_ENTITLEMENTS"] as? String, !path.isEmpty {
        let data = try Data(contentsOf: root.appendingPathComponent(path))
        guard let values = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw CommandError(message: "Cannot read the app's signing entitlements.")
        }
        entitlements = values
    }
    let cloudEnvironment = entitlements["com.apple.developer.icloud-container-environment"] as? String
    let capabilityRevision: String
    if entitlements["aps-environment"] != nil || cloudEnvironment != nil {
        let data = try PropertyListSerialization.data(fromPropertyList: entitlements, format: .xml, options: 0)
        capabilityRevision = " " + SHA256.hash(data: data).prefix(6).map { String(format: "%02x", $0) }.joined()
    } else {
        capabilityRevision = ""
    }
    let profile = try directProfile(client: client, configuration: configuration, metadata: metadata, cache: cache, capabilityRevision: capabilityRevision)
    let archive = cache.appendingPathComponent("Direct.xcarchive")
    if files.fileExists(atPath: archive.path) { try files.removeItem(at: archive) }
    status("Archiving \(metadata.name) build \(build) for the personal iPhone…")
    try run("/usr/bin/xcodebuild", projectArguments + ["-destination", "generic/platform=iOS", "-derivedDataPath", cache.deletingLastPathComponent().appendingPathComponent("DerivedData").path, "-archivePath", archive.path, "-quiet", "archive", "CURRENT_PROJECT_VERSION=\(build)", "DEVELOPMENT_TEAM=\(TestFlightConfiguration.personalTeam)", "CODE_SIGN_STYLE=Manual", "CODE_SIGN_IDENTITY=\(configuration.certificateSHA1)", "PROVISIONING_PROFILE_SPECIFIER=\(profile)"], log: cache.appendingPathComponent("archive.log"))
    guard try sourceFingerprint(root) == fingerprint else {
        throw CommandError(message: "Sources changed during the archive. Finish edits and rerun; no package was published.")
    }
    let export = cache.appendingPathComponent("Export")
    var options: [String: Any] = ["method": "release-testing", "destination": "export", "signingStyle": "manual", "teamID": TestFlightConfiguration.personalTeam, "signingCertificate": configuration.certificateSHA1, "provisioningProfiles": [metadata.bundleIdentifier: profile], "manageAppVersionAndBuildNumber": false, "stripSwiftSymbols": true, "thinning": "<none>"]
    if let cloudEnvironment { options["iCloudContainerEnvironment"] = cloudEnvironment }
    let optionsFile = cache.appendingPathComponent("ExportOptions.plist")
    try PropertyListSerialization.data(fromPropertyList: options, format: .xml, options: 0).write(to: optionsFile, options: .atomic)
    try run("/usr/bin/xcodebuild", ["-exportArchive", "-archivePath", archive.path, "-exportOptionsPlist", optionsFile.path, "-exportPath", export.path], log: cache.appendingPathComponent("export.log"))
    let package = export.appendingPathComponent("\(metadata.name).ipa")
    let unpacked = cache.appendingPathComponent("Verified")
    if files.fileExists(atPath: unpacked.path) { try files.removeItem(at: unpacked) }
    try run("/usr/bin/ditto", ["-x", "-k", package.path, unpacked.path], log: nil)
    defer { try? files.removeItem(at: unpacked) }
    let application = unpacked.appendingPathComponent("Payload/\(metadata.name).app")
    try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", application.path], log: nil)
    let signature = try run("/usr/bin/codesign", ["-dvv", application.path], log: nil)
    guard signature.split(separator: "\n").contains("TeamIdentifier=\(TestFlightConfiguration.personalTeam)") else {
        throw CommandError(message: "Exported package has the wrong signing team.")
    }
    let decoded = try run("/usr/bin/security", ["cms", "-D", "-i", application.appendingPathComponent("embedded.mobileprovision").path], log: nil, separateError: true)
    guard let profileValues = try PropertyListSerialization.propertyList(from: Data(decoded.utf8), format: nil) as? [String: Any],
          let information = try PropertyListSerialization.propertyList(from: Data(contentsOf: application.appendingPathComponent("Info.plist")), format: nil) as? [String: Any],
          information["CFBundleIdentifier"] as? String == metadata.bundleIdentifier,
          information["CFBundleVersion"] as? String == build,
          let version = information["CFBundleShortVersionString"] as? String,
          let minimumOSVersion = information["MinimumOSVersion"] as? String else {
        throw CommandError(message: "Exported package identity or version does not match the requested app.")
    }
    if let cloudEnvironment {
        let signed = try run("/usr/bin/codesign", ["-d", "--entitlements", ":-", application.path], log: nil, separateError: true)
        guard let values = try PropertyListSerialization.propertyList(from: Data(signed.utf8), format: nil) as? [String: Any],
              values["com.apple.developer.icloud-container-environment"] as? String == cloudEnvironment,
              values["aps-environment"] as? String == entitlements["aps-environment"] as? String else {
            throw CommandError(message: "Export changed the app's CloudKit or push environment.")
        }
    }
    let expiration = try verifyDirectProfile(profileValues, bundle: metadata.bundleIdentifier, deviceUDID: configuration.deviceUDID)
    let data = try Data(contentsOf: package, options: .mappedIfSafe)
    let result = DirectPackage(name: information["CFBundleDisplayName"] as? String ?? metadata.name, bundleIdentifier: metadata.bundleIdentifier, version: version, build: build, minimumOSVersion: minimumOSVersion, profileExpiration: expiration, fingerprint: fingerprint, path: package.path, sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), size: data.count)
    try JSONEncoder().encode(result).write(to: state, options: .atomic)
    return result
}
