import Foundation
import os
import Security

/// Stores the session token in the Keychain, never in UserDefaults. The Keychain is safe to
/// use from any thread, so this is not tied to the main actor: the API client reads the token
/// from its own tasks, and intents from theirs.
///
/// On the Mac it uses the data protection keychain, as iOS does, rather than the login keychain,
/// whose items belong to the signature of the build that saved them and can ask for the login
/// password: refusing that prompt would read as no token.
nonisolated enum Keychain {
    private static let service = "app.zimam.session"

    /// The Keychain could not answer (locked, or a prompt was refused): not the same as having no
    /// token, which `value(_:)` reports as nil.
    nonisolated struct Unavailable: Error {
        let status: OSStatus
    }

    /// The value, or nil when there is none. Throws when the Keychain cannot answer, so a caller
    /// never takes a passing failure for "signed out".
    static func value(_ account: String) throws -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            #if os(macOS)
            return try moveFromLoginKeychain(account)
            #else
            return nil
            #endif
        default:
            throw Unavailable(status: status)
        }
    }

    /// `value(_:)` for callers that only need a best guess: nil when the Keychain cannot answer.
    static func read(_ account: String) -> String? {
        try? value(account)
    }

    /// False when the Keychain did not keep it.
    @discardableResult
    static func write(_ value: String, for account: String) -> Bool {
        delete(account)
        var attributes = baseQuery(account)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        attributes[kSecValueData as String] = Data(value.utf8)
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
    }

    private static func baseQuery(_ account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }

    #if os(macOS)
    /// A read of the login keychain that got no answer this launch (a refused password prompt):
    /// not asked again until the next launch, so a refusal does not bring the prompt back with
    /// every request. Reads of the token meanwhile throw, as the Keychain cannot answer.
    private static let loginRefusal = OSAllocatedUnfairLock<OSStatus?>(initialState: nil)

    /// Mac builds before the data protection keychain kept the token in the login keychain. It is
    /// moved here on the first read that finds nothing, so updating does not sign anyone out.
    /// Marked done only on a clear answer, the token moved or none there, after which the login
    /// keychain is not read again. A refused prompt throws, rather than read as signed out for
    /// good, and is asked again on the next launch; a locked keychain, on the next read.
    private static func moveFromLoginKeychain(_ account: String) throws -> String? {
        let movedKey = "keychain.movedFromLogin.\(account)"
        guard !UserDefaults.standard.bool(forKey: movedKey) else { return nil }
        if let refused = loginRefusal.withLock({ $0 }) { throw Unavailable(status: refused) }
        let legacy: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        var query = legacy
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
                UserDefaults.standard.set(true, forKey: movedKey)
                return nil
            }
            // Only once it is kept here: a write that failed leaves it there for the next read.
            if write(value, for: account) {
                SecItemDelete(legacy as CFDictionary)
                UserDefaults.standard.set(true, forKey: movedKey)
            }
            return value
        case errSecItemNotFound:
            UserDefaults.standard.set(true, forKey: movedKey)
            return nil
        default:
            // Locked with no prompt shown: asked again on the next read. Otherwise not this launch.
            if status != errSecInteractionNotAllowed { loginRefusal.withLock { $0 = status } }
            throw Unavailable(status: status)
        }
    }
    #endif
}
