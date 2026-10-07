import Foundation
import Security
import OSLog

struct ShelfVersionReceipt: Codable {
    let version: String
    let build: String
    let lastOpened: Date

    private static let service = "com.lucaswkuipers.shelf.versions"

    static func recordCurrentBuild() {
        do {
            guard let identifier = Bundle.main.bundleIdentifier,
                  let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
                  let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String else {
                throw ReceiptError(message: "Missing app version information.")
            }
            let receipt = Self(version: version, build: build, lastOpened: Date())
            let query = try query(identifier: identifier)
            let attributes: [String: Any] = [
                kSecValueData as String: try JSONEncoder().encode(receipt),
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            ]
            var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if status == errSecItemNotFound {
                status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
            }
            guard status == errSecSuccess else {
                throw ReceiptError(message: "Cannot report the app version (\(status)).")
            }
        } catch {
            Logger(subsystem: service, category: "version").error("\(error.localizedDescription, privacy: .public)")
        }
    }

    static func read(identifier: String) throws -> Self? {
        var query = try query(identifier: identifier)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw ReceiptError(message: "Cannot read the last opened app version (\(status)).")
        }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    func isCurrent(version: String, build: String) -> Bool {
        let comparison = self.version.compare(version, options: .numeric)
        return comparison == .orderedDescending || (comparison == .orderedSame && self.build.compare(build, options: .numeric) != .orderedAscending)
    }

    private static func query(identifier: String) throws -> [String: Any] {
        guard let group = Bundle.main.infoDictionary?["ShelfVersionAccessGroup"] as? String, !group.isEmpty else {
            throw ReceiptError(message: "Missing shelf version sharing configuration.")
        }
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: identifier,
            kSecAttrAccessGroup as String: group
        ]
    }

    private struct ReceiptError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
