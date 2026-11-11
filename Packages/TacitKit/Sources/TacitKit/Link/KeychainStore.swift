import Foundation
import Security

public struct KeychainError: Error, Equatable, CustomStringConvertible {
    public var status: OSStatus

    public var description: String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
    }
}

/// Generic-password items under one service name. Holds this device's id and the per-peer link keys.
public struct KeychainStore: Sendable {
    public static let `default` = KeychainStore(service: "com.tacittype.link")

    private static let deviceIdAccount = "device-id"

    public let service: String

    public init(service: String) {
        self.service = service
    }

    public func data(for account: String) throws -> Data? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw KeychainError(status: status)
        }
    }

    public func set(_ data: Data, for account: String) throws {
        let update = SecItemUpdate(baseQuery(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeychainError(status: update) }

        var item = baseQuery(account)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let add = SecItemAdd(item as CFDictionary, nil)
        guard add == errSecSuccess else { throw KeychainError(status: add) }
    }

    public func delete(_ account: String) throws {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    // MARK: Link keys

    public func linkKey(for peer: UUID) throws -> Data? {
        try data(for: "peer-\(peer.uuidString)")
    }

    public func setLinkKey(_ key: Data, for peer: UUID) throws {
        try set(key, for: "peer-\(peer.uuidString)")
    }

    public func deleteLinkKey(for peer: UUID) throws {
        try delete("peer-\(peer.uuidString)")
    }

    /// This device's stable id, created on first use.
    public func deviceId() throws -> UUID {
        if let data = try data(for: Self.deviceIdAccount),
           let id = UUID(uuidString: String(decoding: data, as: UTF8.self)) {
            return id
        }
        let id = UUID()
        try set(Data(id.uuidString.utf8), for: Self.deviceIdAccount)
        return id
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
