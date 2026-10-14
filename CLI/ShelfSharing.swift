import CoreImage
import CryptoKit
import Foundation
import ImageIO

struct ShelfSharedDevice: Codable {
    let id: String
    let udid: String
    let name: String
}

struct ShelfSharing: Codable {
    static let path = TestFlightConfiguration.directory.appendingPathComponent("shelf-sharing.json")

    var devices: [ShelfSharedDevice]
    var inviteGist: String?

    static func load() throws -> Self {
        guard files.fileExists(atPath: path.path) else {
            return Self(devices: [], inviteGist: nil)
        }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: path))
    }

    func save() throws {
        try JSONEncoder().encode(self).write(to: Self.path, options: .atomic)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.path.path)
    }
}

struct ShelfDevices {
    let ownerDeviceID: String
    let deviceIDs: [String]
    let udids: [String]
    let identifier: String

    init(configuration: DirectConfiguration, sharing: ShelfSharing) {
        ownerDeviceID = configuration.deviceID
        deviceIDs = [configuration.deviceID] + sharing.devices.map(\.id)
        udids = [configuration.deviceUDID] + sharing.devices.map(\.udid)
        if sharing.devices.isEmpty {
            identifier = configuration.deviceID
        } else {
            identifier = SHA256.hash(data: Data(deviceIDs.sorted().joined(separator: ",").utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        }
    }

    static func load() throws -> Self {
        Self(configuration: try DirectConfiguration.load(), sharing: try ShelfSharing.load())
    }

    func isCurrent(_ application: ShelfApplication) -> Bool {
        (application.deviceSet ?? ownerDeviceID) == identifier
    }

    func includes(_ udid: String) -> Bool {
        udids.contains { $0.caseInsensitiveCompare(udid) == .orderedSame }
    }
}

struct ShelfInvite {
    let link: String
    let pinnedLink: String
    let manifestURL: String
    let manifest: Data
    let qrCode: URL
}

func shelfInstallLink(manifestURL: String) throws -> String {
    var components = URLComponents()
    components.scheme = "itms-services"
    components.host = ""
    components.queryItems = [URLQueryItem(name: "action", value: "download-manifest"), URLQueryItem(name: "url", value: manifestURL)]
    guard let link = components.url?.absoluteString else {
        throw CommandError(message: "Cannot create the AppShelf install link.")
    }
    return link
}

func appleDeviceName(_ name: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
    let scalars = name.replacingOccurrences(of: "\u{2019}", with: "").replacingOccurrences(of: "'", with: "").unicodeScalars
    let words = String(String.UnicodeScalarView(scalars.map { $0.isASCII && allowed.contains($0) ? $0 : " " })).split(separator: " ")
    return words.isEmpty ? "Shared iPhone" : String(words.joined(separator: " ").prefix(50))
}

func shareShelf(options: Options) throws {
    let lock = try lockShelfShare()
    defer { close(lock) }
    if options.automatic && setpriority(PRIO_DARWIN_PROCESS, 0, 0) != 0 {
        status("Could not lift background throttling; re-signing may run slowly.")
    }
    let udid = options.values["--device"]
    let name = options.values["--name"]
    let removal = options.values["--remove"]
    if let udid, let name, removal == nil {
        try addShelfDevice(udid: udid, name: name)
    } else if let removal, udid == nil, name == nil {
        try removeShelfDevice(removal)
    } else if udid != nil || name != nil || removal != nil {
        throw CommandError(message: "Use --device <iPhone-UDID> --name <device-name> to approve an iPhone, --remove <device-name-or-UDID> to remove one, or no options to resume sharing.")
    }
    let store = try ShelfStore()
    let devices = try ShelfDevices.load()
    let session = URLSession(configuration: .ephemeral, delegate: RejectRedirect(), delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    let requests = try ShelfRequests.load(session: session)
    var memory = options.automatic ? try ShelfResignMemory.load() : ShelfResignMemory(failures: [:])
    try memory.save()
    func resign(_ application: ShelfApplication) throws {
        do {
            try resignShelfApplication(application, store: store, devices: devices)
        } catch {
            memory.record(application, devices: devices, reason: error.localizedDescription, at: Date())
            try memory.save()
            throw error
        }
        memory.failures[application.bundleIdentifier] = nil
        try memory.save()
    }
    var invite: ShelfInvite?
    var shelfFailure: Error?
    do {
        let (_, catalog) = try store.catalog()
        if let shelf = outstandingResigns(catalog, devices: devices, memory: memory, at: Date()).first(where: { $0.bundleIdentifier == "com.lucaswkuipers.AppShelf" }) {
            try resign(shelf)
        }
        let published = try publishShelfInvite(store: store, devices: devices)
        try requests?.setInstallLink(published.pinnedLink)
        invite = published
        requests?.markReady(devices: devices)
    } catch {
        shelfFailure = error
        status("AppShelf is not ready for every shelf iPhone; re-signing the other apps anyway: \(error.localizedDescription)")
    }
    let unavailable: [String]
    do {
        for _ in 0..<3 {
            let (_, latest) = try store.catalog()
            let batch = outstandingResigns(latest, devices: devices, memory: memory, at: Date())
            guard !batch.isEmpty else {
                break
            }
            for application in batch {
                do {
                    try resign(application)
                } catch {
                    status("Could not re-sign \(application.name); it retries later with backoff: \(error.localizedDescription)")
                }
            }
        }
        let (_, final) = try store.catalog()
        unavailable = final.applications.filter { !devices.isCurrent($0) }.map(\.name)
    } catch {
        requests?.fail(devices: devices, detail: error.localizedDescription)
        throw error
    }
    if let shelfFailure {
        requests?.fail(devices: devices, detail: "AppShelf: \(shelfFailure.localizedDescription)")
        throw shelfFailure
    }
    guard let invite else {
        preconditionFailure("A successful AppShelf step always publishes the invite.")
    }
    requests?.finish(devices: devices, sharing: try ShelfSharing.load(), unavailable: unavailable)
    do {
        try verifyPublicDownload(invite.manifestURL, expected: invite.manifest)
    } catch {
        status("The invite link may install the previous AppShelf build for a few more minutes: \(error.localizedDescription)")
    }
    let shared = try ShelfSharing.load().devices.map(\.name).joined(separator: ", ")
    try emit(["result": "shelf-shared", "sharedWith": shared, "invite": invite.link, "qrCode": invite.qrCode.path, "pendingApps": String(unavailable.count)])
    guard unavailable.isEmpty else {
        throw CommandError(message: "The invite works, but these apps are not yet signed for every shelf iPhone. They retry automatically with backoff, or rerun uikit-app share-shelf:\n" + unavailable.joined(separator: "\n"))
    }
}

@discardableResult
func addShelfDevice(udid: String, name: String) throws -> Bool {
    try validate(udid, pattern: "^[A-Fa-f0-9-]{25,40}$", label: "device UDID")
    guard !name.isEmpty, name.count <= 50 else {
        throw CommandError(message: "Use a device name of 1 to 50 characters.")
    }
    let configuration = try DirectConfiguration.load()
    var sharing = try ShelfSharing.load()
    let known = [configuration.deviceUDID] + sharing.devices.map(\.udid)
    guard !known.contains(where: { $0.caseInsensitiveCompare(udid) == .orderedSame }) else {
        status("\(name) is already approved for the shelf.")
        return false
    }
    let registeredName = appleDeviceName(name)
    let client = try AppStoreClient(configuration: TestFlightConfiguration.load())
    try client.verifyPersonalAccount()
    let device: AppleResource
    if let existing = try client.list("/v1/devices", query: ["filter[udid]": udid]).first {
        guard existing.string("status") == "ENABLED", existing.string("platform") == "IOS" else {
            throw CommandError(message: "This device is registered with the personal team but is not an enabled iOS device. Enable it in the Apple Developer account, then retry.")
        }
        device = existing
    } else {
        status("Registering \(registeredName) with personal team \(TestFlightConfiguration.personalTeam)…")
        device = try client.create(type: "devices", attributes: ["name": registeredName, "udid": udid, "platform": "IOS"], relationships: [:])
    }
    guard let registered = device.string("udid") else {
        throw CommandError(message: "Apple did not return the registered device UDID.")
    }
    sharing.devices.append(ShelfSharedDevice(id: device.id, udid: registered, name: registeredName))
    try sharing.save()
    return true
}

func removeShelfDevice(_ identifier: String) throws {
    var sharing = try ShelfSharing.load()
    let matches = sharing.devices.filter { $0.udid.caseInsensitiveCompare(identifier) == .orderedSame || $0.name == identifier }
    guard let device = matches.first, matches.count == 1 else {
        let names = sharing.devices.map(\.name).joined(separator: ", ")
        throw CommandError(message: matches.isEmpty ? "No shared iPhone matches \(identifier). Shared iPhones: \(names.isEmpty ? "none" : names)." : "Several shared iPhones are named \(identifier). Remove one by its UDID.")
    }
    sharing.devices.removeAll { $0.id == device.id }
    try sharing.save()
    status("Removed \(device.name). Re-signing every shelf app without it…")
}

func resignShelfApplication(_ application: ShelfApplication, store: ShelfStore, devices: ShelfDevices) throws {
    let (_, catalog) = try store.catalog()
    guard let current = catalog.applications.first(where: { $0.bundleIdentifier == application.bundleIdentifier }), !devices.isCurrent(current) else {
        return
    }
    let asset = try store.decoder.decode(ShelfAsset.self, from: Data(store.github.call(["api", "repos/\(ShelfStore.repository)/releases/assets/\(current.packageAssetID)"]).utf8))
    try validate(asset.name, pattern: "^[A-Za-z][A-Za-z0-9]*\\.ipa$", label: "shelf package name")
    try validate(current.sourceCommit, pattern: "^[0-9a-f]{40}$", label: "cataloged source commit")
    let name = String(asset.name.dropLast(".ipa".count))
    _ = try store.github.repository(name: name)
    do {
        try resignShelfPackage(current, name: name, store: store, devices: devices)
    } catch {
        status("Rebuilding \(current.name) because its package could not be re-signed directly: \(error.localizedDescription)")
        try rebuildShelfApplication(current, name: name, store: store, devices: devices)
    }
    let (_, updated) = try store.catalog()
    guard let resigned = updated.applications.first(where: { $0.bundleIdentifier == application.bundleIdentifier }), devices.isCurrent(resigned) else {
        throw CommandError(message: "The re-signed build of \(current.name) was not published for every shelf iPhone.")
    }
}

func resignShelfPackage(_ current: ShelfApplication, name: String, store: ShelfStore, devices: ShelfDevices) throws {
    let configuration = try DirectConfiguration.load()
    let work = files.temporaryDirectory.appendingPathComponent("shelf-resign-\(UUID().uuidString)")
    try files.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? files.removeItem(at: work) }
    status("Re-signing \(current.name) \(current.version) (\(current.build)) for \(devices.udids.count) iPhones…")
    let original = try shelfInstallPackage(current, store: store, cache: work)
    let unpacked = work.appendingPathComponent("Unpacked")
    try run("/usr/bin/ditto", ["-x", "-k", original.path, unpacked.path], log: nil)
    let payload = unpacked.appendingPathComponent("Payload")
    guard try files.contentsOfDirectory(atPath: payload.path) == ["\(name).app"] else {
        throw CommandError(message: "The package does not contain exactly \(name).app.")
    }
    let bundle = payload.appendingPathComponent("\(name).app")
    let nested = ["Frameworks", "PlugIns", "Extensions", "Watch", "AppClips"].filter { files.fileExists(atPath: bundle.appendingPathComponent($0).path) }
    guard nested.isEmpty else {
        throw CommandError(message: "It contains \(nested.joined(separator: ", ")), which only a rebuild signs correctly.")
    }
    let embedded = bundle.appendingPathComponent("embedded.mobileprovision")
    func profile(at path: URL) throws -> [String: Any] {
        let decoded = try run("/usr/bin/security", ["cms", "-D", "-i", path.path], log: nil, separateError: true)
        guard let values = try PropertyListSerialization.propertyList(from: Data(decoded.utf8), format: nil) as? [String: Any] else {
            throw CommandError(message: "Cannot read the provisioning profile at \(path.lastPathComponent).")
        }
        return values
    }
    func entitlements() throws -> NSDictionary {
        let signed = try run("/usr/bin/codesign", ["-d", "--entitlements", "-", "--xml", bundle.path], log: nil, separateError: true)
        guard let values = try PropertyListSerialization.propertyList(from: Data(signed.utf8), format: nil) as? NSDictionary else {
            throw CommandError(message: "Cannot read the signed entitlements.")
        }
        return values
    }
    let previous = try profile(at: embedded)
    let prefix = "UIKit App \(current.bundleIdentifier) "
    guard let previousName = previous["Name"] as? String, previousName.hasPrefix(prefix) else {
        throw CommandError(message: "It was not signed with a UIKit App shelf profile.")
    }
    let nameParts = previousName.dropFirst(prefix.count).split(separator: " ")
    guard nameParts.count == 2 || (nameParts.count == 3 && nameParts[2].range(of: "^[0-9a-f]{12}$", options: .regularExpression) != nil) else {
        throw CommandError(message: "Its profile name \(previousName) has an unexpected form.")
    }
    let capabilityRevision = nameParts.count == 3 ? " \(nameParts[2])" : ""
    let client = try AppStoreClient(configuration: TestFlightConfiguration.load())
    try client.verifyPersonalAccount()
    _ = try directProfile(client: client, configuration: configuration, devices: devices, metadata: Project(name: name, bundleIdentifier: current.bundleIdentifier, delivery: .shelf), cache: work, capabilityRevision: capabilityRevision)
    let replacement = work.appendingPathComponent("Direct.mobileprovision")
    let updated = try profile(at: replacement)
    guard let previousEntitlements = previous["Entitlements"] as? NSDictionary, let updatedEntitlements = updated["Entitlements"] as? NSDictionary, previousEntitlements.isEqual(updatedEntitlements) else {
        throw CommandError(message: "Its App ID capabilities changed since it was built.")
    }
    let signed = try entitlements()
    let signedFile = work.appendingPathComponent("Entitlements.plist")
    try PropertyListSerialization.data(fromPropertyList: signed, format: .xml, options: 0).write(to: signedFile)
    try files.removeItem(at: embedded)
    try files.copyItem(at: replacement, to: embedded)
    try run("/usr/bin/codesign", ["--force", "--sign", configuration.certificateSHA1, "--entitlements", signedFile.path, "--generate-entitlement-der", "--timestamp=none", bundle.path], log: nil)
    try verifyShelfInstall(bundle, application: current, provisioning: .exactly(devices.udids))
    guard try entitlements().isEqual(signed) else {
        throw CommandError(message: "Re-signing changed its entitlements.")
    }
    let expiration = try verifyDirectProfile(updated, bundle: current.bundleIdentifier, provisioning: .exactly(devices.udids))
    let package = work.appendingPathComponent("\(name).ipa")
    try run("/usr/bin/ditto", ["-c", "-k", "--norsrc", "--keepParent", payload.path, package.path], log: nil)
    let data = try Data(contentsOf: package, options: .mappedIfSafe)
    let sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    let intent = ["sourceCommit": current.sourceCommit, "bundleIdentifier": current.bundleIdentifier, "build": current.build, "deviceSet": devices.identifier]
    let application = try publishShelfArtifact(store: store, tag: "\(name)-\(current.build)-\(current.sourceCommit.prefix(12))-\(devices.identifier)", title: "\(name) \(current.version) (\(current.build))", intent: intent, package: package, assetName: "\(name).ipa", size: data.count, sha256: sha256) { asset in
        ShelfApplication(name: current.name, bundleIdentifier: current.bundleIdentifier, version: current.version, build: current.build, minimumOSVersion: current.minimumOSVersion, profileExpiration: expiration, sourceCommit: current.sourceCommit, sha256: sha256, size: data.count, packageAssetID: asset.id, publishedAt: current.publishedAt, manifestAssetID: nil, installExpiration: nil, iconPNG: current.iconPNG, notificationTitle: current.notificationTitle, deviceSet: devices.identifier, silent: true, releaseNotes: current.releaseNotes)
    }
    try withShelfLock {
        let (release, latest) = try store.catalog()
        guard let index = latest.applications.firstIndex(where: { $0.bundleIdentifier == current.bundleIdentifier }),
              latest.applications[index].sourceCommit == current.sourceCommit, latest.applications[index].build == current.build else {
            return
        }
        var catalog = latest
        catalog.applications[index] = application
        try store.updateBody(catalog, releaseID: release.id)
        _ = try store.refresh()
    }
}

func rebuildShelfApplication(_ current: ShelfApplication, name: String, store: ShelfStore, devices: ShelfDevices) throws {
    let capacity = try files.homeDirectoryForCurrentUser.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
    guard capacity > 3_000_000_000 else {
        throw CommandError(message: "Only \(capacity / 1_000_000) MB of disk space is free; re-signing needs at least 3 GB. Free some space; the share retries automatically.")
    }
    let checkout = files.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/uikit-app/Resign/\(name)")
    let credentials = ["-c", "credential.helper=", "-c", "credential.helper=!\(PersonalGitHub.executable) auth git-credential"]
    func prepare() throws {
        if !files.fileExists(atPath: checkout.appendingPathComponent(".git").path) {
            if files.fileExists(atPath: checkout.path) {
                try files.removeItem(at: checkout)
            }
            try files.createDirectory(at: checkout.deletingLastPathComponent(), withIntermediateDirectories: true)
            try store.github.git(checkout.deletingLastPathComponent(), credentials + ["clone", "--quiet", "--no-checkout", "https://github.com/lucaswkuipers/\(name).git", checkout.path], remote: true)
        }
        try store.github.git(checkout, credentials + ["fetch", "--quiet", "origin"], remote: true)
        try store.github.git(checkout, ["checkout", "--quiet", "--force", "--detach", current.sourceCommit], remote: false)
        try store.github.git(checkout, ["clean", "--quiet", "-ffdx"], remote: false)
    }
    do {
        try prepare()
    } catch {
        status("Recreating the re-sign checkout of \(name): \(error.localizedDescription)")
        try files.removeItem(at: checkout)
        do {
            try prepare()
        } catch {
            throw CommandError(message: "Cannot check out \(name) at its cataloged commit \(current.sourceCommit.prefix(7)); if that commit was removed from GitHub, push a new commit to rebuild it. \(error.localizedDescription)")
        }
    }
    if current.bundleIdentifier == "com.lucaswkuipers.AppShelf" {
        let access = checkout.appendingPathComponent("AppShelf/ShelfAccess.generated.json")
        try files.copyItem(at: TestFlightConfiguration.directory.appendingPathComponent("shelf-access.json"), to: access)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: access.path)
    }
    status("Rebuilding \(current.name) \(current.version) from \(current.sourceCommit.prefix(7)) for \(devices.udids.count) iPhones…")
    try deliverDirect(directory: checkout.path)
}

func publishShelfInvite(store: ShelfStore, devices: ShelfDevices) throws -> ShelfInvite {
    let (_, catalog) = try store.catalog()
    guard let application = catalog.applications.first(where: { $0.bundleIdentifier == "com.lucaswkuipers.AppShelf" }),
          devices.isCurrent(application), application.profileExpiration > Date().addingTimeInterval(86400) else {
        throw CommandError(message: "AppShelf needs a current build signed for every shelf iPhone. Rerun uikit-app share-shelf.")
    }
    let work = files.temporaryDirectory.appendingPathComponent("shelf-invite-\(UUID().uuidString)")
    try files.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? files.removeItem(at: work) }
    let package = try shelfInstallPackage(application, store: store, cache: work)
    let unpacked = work.appendingPathComponent("Unpacked")
    try run("/usr/bin/ditto", ["-x", "-k", package.path, unpacked.path], log: nil)
    try verifyShelfInstall(unpacked.appendingPathComponent("Payload/AppShelf.app"), application: application, provisioning: .exactly(devices.udids))
    let readme = """
    # AppShelf

    Lucas's private app shelf. Open the install link on an iPhone that Lucas has added to the shelf, then open AppShelf, allow notifications, and install apps from the list.

    """
    var sharing = try ShelfSharing.load()
    let gist: String
    if let inviteGist = sharing.inviteGist {
        gist = inviteGist
    } else {
        struct Gist: Decodable {
            let id: String
            let `public`: Bool
        }
        let request = work.appendingPathComponent("gist.json")
        try JSONSerialization.data(withJSONObject: ["description": "AppShelf invite", "public": false, "files": ["README.md": ["content": readme]]]).write(to: request)
        let created = try JSONDecoder().decode(Gist.self, from: Data(store.github.call(["api", "--method", "POST", "gists", "--input", request.path]).utf8))
        guard !created.public else {
            throw CommandError(message: "GitHub created public gist \(created.id) instead of a secret one. Delete it before retrying.")
        }
        sharing.inviteGist = created.id
        try sharing.save()
        gist = created.id
    }
    try validate(gist, pattern: "^[0-9a-f]{20,40}$", label: "invite gist")
    let checkout = work.appendingPathComponent("Gist")
    let credentials = ["-c", "credential.helper=", "-c", "credential.helper=!\(PersonalGitHub.executable) auth git-credential"]
    try store.github.git(work, credentials + ["clone", "--quiet", "https://gist.github.com/\(gist).git", checkout.path], remote: true)
    let packageCopy = checkout.appendingPathComponent("AppShelf.ipa")
    if files.fileExists(atPath: packageCopy.path) {
        try files.removeItem(at: packageCopy)
    }
    try files.copyItem(at: package, to: packageCopy)
    let raw = "https://gist.githubusercontent.com/lucaswkuipers/\(gist)/raw"
    let packageURL = "\(raw)/\(try store.github.git(checkout, ["hash-object", "AppShelf.ipa"], remote: false))/AppShelf.ipa"
    let manifest: [String: Any] = ["items": [["assets": [["kind": "software-package", "url": packageURL]], "metadata": ["bundle-identifier": application.bundleIdentifier, "bundle-version": application.build, "kind": "software", "title": application.name]]]]
    let manifestData = try PropertyListSerialization.data(fromPropertyList: manifest, format: .xml, options: 0)
    try manifestData.write(to: checkout.appendingPathComponent("AppShelf.plist"), options: .atomic)
    try readme.write(to: checkout.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    let manifestURL = "\(raw)/AppShelf.plist"
    let pinnedManifestURL = "\(raw)/\(try store.github.git(checkout, ["hash-object", "AppShelf.plist"], remote: false))/AppShelf.plist"
    if try !store.github.git(checkout, ["status", "--porcelain"], remote: false).isEmpty {
        try store.github.git(checkout, ["add", "--all"], remote: false)
        try store.github.git(checkout, ["-c", "user.name=Lucas Werner Kuipers", "-c", "user.email=lucaswkuipers@gmail.com", "commit", "--quiet", "-m", "AppShelf \(application.version) (\(application.build))"], remote: false)
        try store.github.git(checkout, credentials + ["push", "--quiet", "origin", "HEAD"], remote: true)
    }
    try verifyPublicDownload(packageURL, expected: Data(contentsOf: package))
    try verifyPublicDownload(pinnedManifestURL, expected: manifestData)
    let link = try shelfInstallLink(manifestURL: manifestURL)
    let directory = files.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/uikit-app/ShelfInvite")
    try files.createDirectory(at: directory, withIntermediateDirectories: true)
    let qrCode = directory.appendingPathComponent("AppShelf-invite.png")
    try writeQRCode(link, to: qrCode)
    return ShelfInvite(link: link, pinnedLink: try shelfInstallLink(manifestURL: pinnedManifestURL), manifestURL: manifestURL, manifest: manifestData, qrCode: qrCode)
}

func verifyPublicDownload(_ url: String, expected: Data) throws {
    let download = files.temporaryDirectory.appendingPathComponent("shelf-download-\(UUID().uuidString)")
    defer { try? files.removeItem(at: download) }
    let deadline = Date().addingTimeInterval(420)
    var waiting = false
    while Date() < deadline {
        do {
            try run("/usr/bin/curl", ["--fail", "--silent", "--show-error", "--max-time", "60", "--output", download.path, url], log: nil)
            if try Data(contentsOf: download) == expected {
                return
            }
        } catch {
            status("Could not download \(url): \(error.localizedDescription)")
        }
        if !waiting {
            status("Waiting for GitHub's cache to serve the updated \(url); this can take five minutes…")
            waiting = true
        }
        Thread.sleep(forTimeInterval: 10)
    }
    throw CommandError(message: "GitHub still does not serve the published AppShelf invite at \(url).")
}

func writeQRCode(_ text: String, to destination: URL) throws {
    guard let generator = CIFilter(name: "CIQRCodeGenerator") else {
        throw CommandError(message: "Core Image cannot generate QR codes.")
    }
    generator.setValue(Data(text.utf8), forKey: "inputMessage")
    generator.setValue("M", forKey: "inputCorrectionLevel")
    guard let code = generator.outputImage?.samplingNearest().transformed(by: CGAffineTransform(scaleX: 12, y: 12)) else {
        throw CommandError(message: "Cannot generate the QR code.")
    }
    let canvas = code.extent.insetBy(dx: -48, dy: -48)
    guard let image = CIContext().createCGImage(code.composited(over: CIImage(color: .white).cropped(to: canvas)), from: canvas),
          let output = CGImageDestinationCreateWithURL(destination as CFURL, "public.png" as CFString, 1, nil) else {
        throw CommandError(message: "Cannot render the QR code.")
    }
    CGImageDestinationAddImage(output, image, nil)
    guard CGImageDestinationFinalize(output) else {
        throw CommandError(message: "Cannot save the QR code to \(destination.path).")
    }
}
