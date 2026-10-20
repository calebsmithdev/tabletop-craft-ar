import Foundation
import Security
import TabletopCore

/// Value adapter owned by WorldSession. The JSON is stored only inside one
/// device-local Keychain item; preferences never contain credentials.
public struct KeychainTokenStorage: TokenStorage {
    private let service = "com.tabletopcraft.ar.visionos.pairings"
    public init() {}
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: "servers"]
    }
    private func read() throws -> PairingStore {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &value)
        if status == errSecItemNotFound { return PairingStore() }
        guard status == errSecSuccess, let data = value as? Data,
              let json = String(data: data, encoding: .utf8) else { throw KeychainError(status: status) }
        return try PairingStore.parse(json)
    }
    private func write(_ store: PairingStore) throws {
        let data = Data(try store.toJson().utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query
            q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(q as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError(status: added) }
        } else if status != errSecSuccess { throw KeychainError(status: status) }
    }
    public func find(_ url: String?, _ serverId: String?) throws -> PairingEntry? { try read().find(url, serverId) }
    public mutating func save(_ serverId: String?, _ url: String?, _ token: String, _ device: String?, _ name: String?, _ nowMs: Int64) throws {
        var store = try read()
        store.save(serverId, url, token, device, name, nowMs)
        try write(store)
    }
    @discardableResult public mutating func seen(_ url: String?, _ serverId: String?) throws -> Bool {
        var store = try read()
        let changed = store.seen(url, serverId)
        if changed { try write(store) }
        return changed
    }
    @discardableResult public mutating func forget(_ url: String?, _ serverId: String?) throws -> Bool {
        var store = try read()
        let changed = store.forget(url, serverId)
        if changed { try write(store) }
        return changed
    }
}

private struct KeychainError: Error, CustomStringConvertible {
    let status: OSStatus
    var description: String { "Keychain: \(SecCopyErrorMessageString(status, nil) as String? ?? String(status))" }
}
