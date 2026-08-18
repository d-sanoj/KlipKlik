import CryptoKit
import Foundation

/// Encrypts anything KlipKlik puts on disk.
///
/// Clipboard history is exactly the sort of thing that should not sit in plain
/// files: passwords, tokens, one-time codes, private messages. Offloading it to
/// SSD to save RAM is only acceptable if what lands there is unreadable to a
/// backup, a copied folder, or anything grepping the disk.
///
/// AES-GCM with a 256-bit key in a `0600` file, deliberately *not* the Keychain.
/// The Keychain gates access on the code signature, and an ad-hoc signature
/// changes with every build — so the stored key stops matching and macOS falls
/// back to asking for the login password, once per access. An app that prompts
/// for your password every few minutes is worse than the threat it defends
/// against, and users learn to type passwords into anything that asks.
///
/// What this buys, honestly: the blobs are useless in a Time Machine backup, on
/// a copied folder, or to anything trawling the disk for readable text, and the
/// key dies on uninstall. What it does not buy: protection from a process
/// already running as you, which can read the key file as easily as the app can.
/// Nothing short of a signed build with a real Keychain entitlement would.
enum SecretBox {
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

    /// Shreds the key, which makes every existing file permanently unreadable.
    /// Faster and more thorough than overwriting blobs, and nothing is
    /// recoverable if one is missed.
    static func destroyKey() {
        try? FileManager.default.removeItem(at: keyURL)
        cached = nil
    }

    private static var cached: SymmetricKey?

    private static var keyURL: URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        return support
            .appendingPathComponent("KlipKlik", isDirectory: true)
            .appendingPathComponent("key")
    }

    private static func key() throws -> SymmetricKey {
        if let cached { return cached }

        let url = keyURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )

        if let data = try? Data(contentsOf: url), data.count == 32 {
            let existing = SymmetricKey(data: data)
            cached = existing
            return existing
        }

        let fresh = SymmetricKey(size: .bits256)
        let raw = fresh.withUnsafeBytes { Data($0) }
        do {
            // Written owner-read-only from the start — never briefly world
            // readable between creating the file and tightening it.
            try raw.write(to: url, options: [.atomic, .completeFileProtection])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path
            )
        } catch {
            throw Failure.noKey
        }

        cached = fresh
        return fresh
    }
}
