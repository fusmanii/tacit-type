import CryptoKit
import Foundation

/// Key material for pairing and for every later connection.
///
/// Pairing runs in two layers. The outer layer is a TLS-PSK handshake keyed from the 6-digit code,
/// which proves both sides saw the same code. Inside it the devices run an X25519 exchange and
/// derive the long-term key from that, so a recording of the pairing session is useless even to
/// someone who brute-forces the code offline.
public enum Pairing {
    public static let codeLength = 6

    /// Failed handshakes allowed on one pairing listener before the iPhone shows a fresh code.
    /// One wrong code from the Mac costs up to one failure per path, because Network.framework races
    /// AWDL, IPv6 and IPv4 at once. 10 still keeps an online guesser at 1 in 100,000 per code.
    public static let maxFailedAttempts = 10

    public static func randomCode() -> String {
        var rng = SystemRandomNumberGenerator()
        return (0 ..< codeLength).map { _ in String(Int.random(in: 0 ... 9, using: &rng)) }.joined()
    }

    public static func isValidCode(_ code: String) -> Bool {
        code.count == codeLength && code.allSatisfy(\.isASCII) && code.allSatisfy(\.isNumber)
    }

    /// PSK for the pairing listener. `HKDF-SHA256(code, salt = iphoneId, info = "tacittype-pair-v1")`.
    /// The Mac's id isn't in the salt because the iPhone has to build this key before any Mac connects.
    public static func pairingKey(code: String, iphoneId: UUID) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(code.utf8)),
                               salt: iphoneId.bytes,
                               info: Data("tacittype-pair-v1".utf8),
                               outputByteCount: 32)
    }

    /// Long-term PSK from the X25519 exchange inside the pairing tunnel.
    public static func longTermKey(privateKey: Curve25519.KeyAgreement.PrivateKey, peerPublicKey: Data,
                                   iphoneId: UUID, macId: UUID) throws -> SymmetricKey {
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        return shared.hkdfDerivedSymmetricKey(using: SHA256.self,
                                              salt: iphoneId.bytes + macId.bytes,
                                              sharedInfo: Data("tacittype-ltk-v1".utf8),
                                              outputByteCount: 32)
    }
}

/// The identity a Mac presents in the TLS-PSK handshake. It tells the iPhone which key to use.
public enum PSKIdentity: Hashable, Sendable {
    /// Used only against the pairing listener.
    case pairing
    /// A paired Mac connecting with its long-term key.
    case paired(macId: UUID)

    public var data: Data {
        switch self {
        case .pairing: Data("tt1-pair".utf8)
        case let .paired(macId): Data("tt1:\(macId.uuidString)".utf8)
        }
    }
}

extension UUID {
    var bytes: Data { withUnsafeBytes(of: uuid) { Data($0) } }
}

extension SymmetricKey {
    public var data: Data { withUnsafeBytes { Data($0) } }
}
