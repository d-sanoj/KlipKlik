import CryptoKit
import Foundation
import Security

/// Encrypts anything KlipKlick puts on disk.
///
/// Clipboard history is exactly the sort of thing that should not sit in plain
/// files: passwords, tokens, one-time codes, private messages. Offloading it to
/// SSD to save RAM is only acceptable if what lands there is unreadable to other
/// users, to backup tools, and to anything else trawling the disk.
///
/// AES-GCM with a 256-bit key kept in the login Keychain. The key never touches
/// the store's directory, so copying the folder elsewhere yields nothing.
enum SecretBox {
    private static let account = "com.sanoj.KlipKlick.storeKey"
    private static let service = "KlipKlick"

    enum Failure: Error { case noKey, corrupt }

    static func seal(_ data: Data) throws -> Data {
        let box = try AES.GCM.seal(data, using: key())
        guard let combined = box.combined else { throw Failure.corrupt }
        return combined
    }

    static func open(_ data: Data) throws -> Data {
        let box = try AES.GCM.SealedBox(combined: data)
        return try AES.GCM.open(box, using: key())
    }

    /// Drops the key, which makes every existing file permanently unreadable.
    /// Used by uninstall: shredding the key is faster and more thorough than
    /// overwriting the files, and leaves nothing recoverable if one is missed.
    static func destroyKey() {
        SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ] as CFDictionary)
        cached = nil
    }

    private static var cached: SymmetricKey?

    /// The store key, created on first use.
    private static func key() throws -> SymmetricKey {
        if let cached { return cached }

        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true
        ]

        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data {
            let existing = SymmetricKey(data: data)
            cached = existing
            return existing
        }

        let fresh = SymmetricKey(size: .bits256)
        let raw = fresh.withUnsafeBytes { Data($0) }
        query[kSecReturnData] = nil
        query[kSecValueData] = raw
        // Readable only once the Mac has been unlocked at least once, and never
        // synced to another device.
        query[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else {
            throw Failure.noKey
        }
        cached = fresh
        return fresh
    }
}
