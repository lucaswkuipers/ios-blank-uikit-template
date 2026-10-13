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
}

struct ShelfInvite {
    let link: String
    let qrCode: URL
}

func shareShelf(options: Options) throws {
    let udid = options.values["--device"]
    let name = options.values["--name"]
    guard (udid == nil) == (name == nil) else {
        throw CommandError(message: "Provide both --device <iPhone-UDID> and --name <device-name>, or neither to resume sharing.")
    }
    if let udid, let name {
        try addShelfDevice(udid: udid, name: name)
    }
    let store = try ShelfStore()
    let devices = try ShelfDevices.load()
    let failures = try resignShelfApplications(store: store, devices: devices)
    let invite = try publishShelfInvite(store: store, devices: devices)
    try emit(["result": "shelf-shared", "iPhones": String(devices.udids.count), "invite": invite.link, "qrCode": invite.qrCode.path, "pendingApps": String(failures.count)])
    guard failures.isEmpty else {
        throw CommandError(message: "The invite works, but some apps are not yet signed for every shelf iPhone. Rerun uikit-app share-shelf to retry them:\n" + failures.joined(separator: "\n"))
    }
}

func addShelfDevice(udid: String, name: String) throws {
    try validate(udid, pattern: "^[A-Fa-f0-9-]{25,40}$", label: "device UDID")
    guard !name.isEmpty, name.count <= 50 else {
        throw CommandError(message: "Use a device name of 1 to 50 characters.")
    }
    let configuration = try DirectConfiguration.load()
    var sharing = try ShelfSharing.load()
    let known = [configuration.deviceUDID] + sharing.devices.map(\.udid)
    guard !known.contains(where: { $0.caseInsensitiveCompare(udid) == .orderedSame }) else {
        status("\(name) is already signed into every shelf app.")
        return
    }
    let client = try AppStoreClient(configuration: TestFlightConfiguration.load())
    try client.verifyPersonalAccount()
    let device: AppleResource
    if let existing = try client.list("/v1/devices", query: ["filter[udid]": udid]).first {
        guard existing.string("status") == "ENABLED", existing.string("platform") == "IOS" else {
            throw CommandError(message: "This device is registered with the personal team but is not an enabled iOS device. Enable it in the Apple Developer account, then retry.")
        }
        device = existing
    } else {
        status("Registering \(name) with personal team \(TestFlightConfiguration.personalTeam)…")
        device = try client.create(type: "devices", attributes: ["name": name, "udid": udid, "platform": "IOS"], relationships: [:])
    }
    guard let registered = device.string("udid") else {
        throw CommandError(message: "Apple did not return the registered device UDID.")
    }
    sharing.devices.append(ShelfSharedDevice(id: device.id, udid: registered, name: name))
    try sharing.save()
}

func resignShelfApplications(store: ShelfStore, devices: ShelfDevices) throws -> [String] {
    let (_, catalog) = try store.catalog()
    let outdated = catalog.applications.filter { !devices.isCurrent($0) }
    let ordered = outdated.filter { $0.bundleIdentifier == "com.lucaswkuipers.AppShelf" } + outdated.filter { $0.bundleIdentifier != "com.lucaswkuipers.AppShelf" }
    var failures: [String] = []
    for application in ordered {
        do {
            let asset = try store.decoder.decode(ShelfAsset.self, from: Data(store.github.call(["api", "repos/\(ShelfStore.repository)/releases/assets/\(application.packageAssetID)"]).utf8))
            try validate(asset.name, pattern: "^[A-Za-z][A-Za-z0-9]*\\.ipa$", label: "shelf package name")
            let repository = try store.github.repository(name: String(asset.name.dropLast(".ipa".count)))
            status("Re-signing \(application.name) for \(devices.udids.count) iPhones…")
            try runShelfWorkflow(repository: repository.nameWithOwner, github: store.github)
            let (_, updated) = try store.catalog()
            guard let resigned = updated.applications.first(where: { $0.bundleIdentifier == application.bundleIdentifier }), devices.isCurrent(resigned) else {
                throw CommandError(message: "Its workflow succeeded without publishing a build for every shelf iPhone.")
            }
        } catch {
            status("Could not re-sign \(application.name): \(error.localizedDescription)")
            failures.append("\(application.name): \(error.localizedDescription)")
        }
    }
    return failures
}

func runShelfWorkflow(repository: String, github: PersonalGitHub) throws {
    let list = ["run", "list", "--repo", repository, "--workflow", DeliveryRoute.shelf.workflow, "--event", "workflow_dispatch", "--json", "databaseId,status,conclusion,url", "--limit", "20"]
    let earlier = Set(try JSONDecoder().decode([DeliveryRun].self, from: Data(github.call(list).utf8)).map(\.databaseId))
    try github.call(["workflow", "run", DeliveryRoute.shelf.workflow, "--repo", repository, "--ref", "main"])
    let deadline = Date().addingTimeInterval(2700)
    var previousStatus = ""
    while Date() < deadline {
        Thread.sleep(forTimeInterval: 10)
        let runs = try JSONDecoder().decode([DeliveryRun].self, from: Data(github.call(list).utf8))
        guard let delivery = runs.first(where: { !earlier.contains($0.databaseId) }) else {
            continue
        }
        if delivery.status != previousStatus {
            status("GitHub delivery: \(delivery.status) — \(delivery.url)")
            previousStatus = delivery.status
        }
        guard delivery.status == "completed" else {
            continue
        }
        guard delivery.conclusion == "success" else {
            throw CommandError(message: "Its shelf workflow finished with \(delivery.conclusion): \(delivery.url)")
        }
        return
    }
    throw CommandError(message: "Its shelf workflow did not finish within 45 minutes.")
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
    try verifyShelfInstall(unpacked.appendingPathComponent("Payload/AppShelf.app"), application: application, devices: devices.udids)
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
    if try !store.github.git(checkout, ["status", "--porcelain"], remote: false).isEmpty {
        try store.github.git(checkout, ["add", "--all"], remote: false)
        try store.github.git(checkout, ["-c", "user.name=Lucas Werner Kuipers", "-c", "user.email=lucaswkuipers@gmail.com", "commit", "--quiet", "-m", "AppShelf \(application.version) (\(application.build))"], remote: false)
        try store.github.git(checkout, credentials + ["push", "--quiet", "origin", "HEAD"], remote: true)
    }
    try verifyPublicDownload(packageURL, expected: Data(contentsOf: package), directory: work)
    try verifyPublicDownload(manifestURL, expected: manifestData, directory: work)
    var components = URLComponents()
    components.scheme = "itms-services"
    components.host = ""
    components.queryItems = [URLQueryItem(name: "action", value: "download-manifest"), URLQueryItem(name: "url", value: manifestURL)]
    guard let link = components.url?.absoluteString else {
        throw CommandError(message: "Cannot create the AppShelf install link.")
    }
    let directory = files.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/uikit-app/ShelfInvite")
    try files.createDirectory(at: directory, withIntermediateDirectories: true)
    let qrCode = directory.appendingPathComponent("AppShelf-invite.png")
    try writeQRCode(link, to: qrCode)
    return ShelfInvite(link: link, qrCode: qrCode)
}

func verifyPublicDownload(_ url: String, expected: Data, directory: URL) throws {
    let download = directory.appendingPathComponent(UUID().uuidString)
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
