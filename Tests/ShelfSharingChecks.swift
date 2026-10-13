import CoreImage
import Foundation

func testShelfSharing(directory: URL) throws {
    let owner = DirectConfiguration(certificateID: "CERTIFICAT", certificateSHA1: "SHA1", deviceID: "OWNERPHONE", deviceUDID: "owner-iphone")
    let solo = ShelfDevices(configuration: owner, sharing: ShelfSharing(devices: [], inviteGist: nil))
    try expect(solo.identifier == "OWNERPHONE" && solo.deviceIDs == ["OWNERPHONE"] && solo.udids == ["owner-iphone"], "Without shared iPhones, signing keeps the owner's existing profiles")
    let friend = ShelfSharedDevice(id: "FRIENDFONE", udid: "friend-iphone", name: "Friend")
    let other = ShelfSharedDevice(id: "OTHERPHONE", udid: "other-iphone", name: "Other")
    let shared = ShelfDevices(configuration: owner, sharing: ShelfSharing(devices: [friend, other], inviteGist: nil))
    let reordered = ShelfDevices(configuration: owner, sharing: ShelfSharing(devices: [other, friend], inviteGist: nil))
    try expect(shared.identifier != solo.identifier && shared.identifier == reordered.identifier, "Shared profiles are identified by their device set, regardless of order")
    try expect(shared.udids == ["owner-iphone", "friend-iphone", "other-iphone"] && shared.deviceIDs.count == 3, "Shared profiles include the owner and every shared iPhone")

    var application = ShelfApplication(name: "Test", bundleIdentifier: "com.lucaswkuipers.Test", version: "1.0", build: "1", minimumOSVersion: "27.0", profileExpiration: .distantFuture, sourceCommit: "commit", sha256: "digest", size: 1, packageAssetID: 1, publishedAt: Date())
    try expect(solo.isCurrent(application) && !shared.isCurrent(application), "Catalog entries from before sharing are signed for the owner's iPhone alone")
    application.deviceSet = shared.identifier
    try expect(shared.isCurrent(application) && !solo.isCurrent(application), "Re-signed catalog entries record their device set")

    let link = "itms-services://?action=download-manifest&url=https://gist.githubusercontent.com/lucaswkuipers/0123456789abcdef0123456789abcdef/raw/0123456789abcdef0123456789abcdef01234567/AppShelf.plist"
    let qrCode = directory.appendingPathComponent("invite.png")
    try writeQRCode(link, to: qrCode)
    guard let image = CIImage(contentsOf: qrCode),
          let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]) else {
        throw CommandError(message: "Cannot read the generated QR code.")
    }
    let messages = detector.features(in: image).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
    try expect(messages == [link], "The invite QR code must scan back to the exact install link")
}
