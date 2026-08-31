import CryptoKit
import Foundation
import Security

/// PEM in, `SecIdentity` out.
///
/// URLSession will only answer a client-certificate challenge with a
/// `SecIdentity`, and a `SecIdentity` only exists as a keychain pairing of a
/// certificate with its private key — there is no way to build one from bytes
/// alone. So the key and certificate are written to the keychain under a tag
/// derived from the cluster, and the identity is read back out. Re-importing the
/// same cluster replaces its entries rather than accumulating them.
public enum Identity {

    public enum Error: Swift.Error, CustomStringConvertible {
        case noPEMBlock(String)
        case badCertificate
        case badPrivateKey(String)
        case keychain(String, OSStatus)

        public var description: String {
            switch self {
            case .noPEMBlock(let label):   return "no \(label) block in the PEM data"
            case .badCertificate:          return "the client certificate is not valid DER"
            case .badPrivateKey(let why):  return "the client key could not be read: \(why)"
            case .keychain(let op, let s):
                let msg = SecCopyErrorMessageString(s, nil) as String? ?? "OSStatus \(s)"
                return "keychain \(op) failed: \(msg)"
            }
        }
    }

    // MARK: - PEM

    /// Every DER block carrying `label`, in file order.
    public static func pemBlocks(_ pem: Data, label: String) -> [Data] {
        guard let text = String(data: pem, encoding: .utf8) else { return [] }
        let begin = "-----BEGIN \(label)-----"
        let end   = "-----END \(label)-----"
        var out: [Data] = []
        var rest = Substring(text)
        while let b = rest.range(of: begin), let e = rest.range(of: end, range: b.upperBound..<rest.endIndex) {
            let body = rest[b.upperBound..<e.lowerBound]
            if let der = Data(base64Encoded: body.replacingOccurrences(of: "\n", with: "")
                                                 .replacingOccurrences(of: "\r", with: ""),
                              options: .ignoreUnknownCharacters) {
                out.append(der)
            }
            rest = rest[e.upperBound...]
        }
        return out
    }

    public static func certificates(fromPEM pem: Data) throws -> [SecCertificate] {
        let ders = pemBlocks(pem, label: "CERTIFICATE")
        guard !ders.isEmpty else { throw Error.noPEMBlock("CERTIFICATE") }
        return try ders.map {
            guard let c = SecCertificateCreateWithData(nil, $0 as CFData) else { throw Error.badCertificate }
            return c
        }
    }

    /// A private key from any of the three encodings kubeconfigs carry.
    ///
    /// `SecKeyCreateWithData` wants the bare key — PKCS#1 for RSA, X9.63 for EC —
    /// so a PKCS#8 or SEC1 wrapper is unwrapped first. kubeadm writes PKCS#1,
    /// which is the case that has to work; the other two are here because other
    /// issuers write them.
    public static func privateKey(fromPEM pem: Data) throws -> SecKey {
        if let der = pemBlocks(pem, label: "RSA PRIVATE KEY").first {
            return try secKey(der: der, type: kSecAttrKeyTypeRSA)
        }
        if let der = pemBlocks(pem, label: "EC PRIVATE KEY").first {
            return try secKey(der: try DER.ecPrivateKeyFromSEC1(der), type: kSecAttrKeyTypeECSECPrimeRandom)
        }
        if let der = pemBlocks(pem, label: "PRIVATE KEY").first {
            let (inner, isEC) = try DER.unwrapPKCS8(der)
            return try secKey(der: isEC ? try DER.ecPrivateKeyFromSEC1(inner) : inner,
                              type: isEC ? kSecAttrKeyTypeECSECPrimeRandom : kSecAttrKeyTypeRSA)
        }
        throw Error.noPEMBlock("PRIVATE KEY")
    }

    static func secKey(der: Data, type: CFString) throws -> SecKey {
        var err: Unmanaged<CFError>?
        let attrs: [CFString: Any] = [
            kSecAttrKeyType: type,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
        ]
        guard let k = SecKeyCreateWithData(der as CFData, attrs as CFDictionary, &err) else {
            let why = (err?.takeRetainedValue()).map { String(describing: $0) } ?? "unrecognised encoding"
            throw Error.badPrivateKey(why)
        }
        return k
    }

    // MARK: - Identity

    /// Import `certPEM` + `keyPEM` under `tag` and return the identity they form.
    ///
    /// `tag` must be stable per cluster: it is what makes a re-import a replace.
    public static func makeIdentity(certPEM: Data, keyPEM: Data, tag: String) throws -> SecIdentity {
        let certs = try certificates(fromPEM: certPEM)
        guard let leaf = certs.first else { throw Error.badCertificate }
        let key = try privateKey(fromPEM: keyPEM)
        let tagData = Data(tag.utf8)
        let keyHash = try publicKeyHash(of: key)

        // Replace, don't accumulate. The certificate is deleted by value as well
        // as by label: an earlier import under a different label would otherwise
        // survive, and the add below would come back errSecDuplicateItem having
        // left the old label in place — which is the label the identity is then
        // looked up by.
        //
        // The key is also deleted by its public-key hash, not only by our tag.
        // A second copy of the same key under a different tag — left by a
        // re-import, or by the context being renamed — makes the TLS handshake
        // fail outright with a peer alert rather than picking either copy. That
        // was not theoretical: it took a working client down to a decode_error
        // until the stale entries were removed.
        SecItemDelete(scoped([kSecClass: kSecClassKey, kSecAttrApplicationTag: tagData]))
        SecItemDelete(scoped([kSecClass: kSecClassKey, kSecAttrApplicationLabel: keyHash]))
        SecItemDelete(scoped([kSecClass: kSecClassCertificate, kSecAttrLabel: tag]))
        SecItemDelete(scoped([kSecClass: kSecClassCertificate, kSecValueRef: leaf]))

        // kSecAttrApplicationLabel is the hinge. The keychain pairs a certificate
        // with a key by looking for a key whose application label equals the
        // SHA-1 of the certificate's public key; a key added without it forms no
        // identity, and the pairing lookup then finds nothing. Security computes
        // this itself for keys it generated — not for one handed to it as bytes.
        // kSecAttrKeyType has to be stated. RSA happens to work without it —
        // it is what the keychain assumes — and an EC key is rejected with
        // "the specified item is no longer valid", which describes nothing. k3s
        // issues EC client certificates, so this is not a corner: it is every
        // k3s cluster.
        var add: [CFString: Any] = [
            kSecClass: kSecClassKey,
            kSecAttrApplicationTag: tagData,
            kSecAttrApplicationLabel: keyHash,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecValueRef: key,
        ]
        if let attributes = SecKeyCopyAttributes(key) as? [CFString: Any],
           let type = attributes[kSecAttrKeyType] {
            add[kSecAttrKeyType] = type
        }
        var status = SecItemAdd(scoped(add), nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw Error.keychain("add key", status)
        }

        status = SecItemAdd(scoped([
            kSecClass: kSecClassCertificate,
            kSecAttrLabel: tag,
            kSecValueRef: leaf,
        ]), nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw Error.keychain("add certificate", status)
        }

        // Read the pairing back as an identity rather than building one with
        // SecIdentityCreateWithCertificate, which returns errSecItemNotFound
        // against the macOS file keychain even when both halves are sitting in
        // it.
        //
        // Matched on the certificate's own bytes, NOT on kSecAttrLabel. A label
        // query here returned this machine's "Apple Development" code-signing
        // identity — the keychain does not constrain an identity search by the
        // label we set, so the first identity in the keychain came back and
        // every request went out as the wrong client. The certificate is the
        // only thing that identifies the pairing unambiguously.
        let want = SecCertificateCopyData(leaf) as Data
        var out: CFTypeRef?
        status = SecItemCopyMatching(scoped([
            kSecClass: kSecClassIdentity,
            kSecMatchLimit: kSecMatchLimitAll,
            kSecReturnRef: true,
        ]), &out)
        guard status == errSecSuccess, let candidates = out as? [SecIdentity] else {
            throw Error.keychain("list identities", status)
        }
        for candidate in candidates {
            var cert: SecCertificate?
            guard SecIdentityCopyCertificate(candidate, &cert) == errSecSuccess,
                  let cert, SecCertificateCopyData(cert) as Data == want else { continue }
            return candidate
        }
        throw Error.keychain("pair certificate with key", errSecItemNotFound)
    }

    /// Forget a cluster's credentials. Removing the context should remove these.
    public static func forget(tag: String, certPEM: Data? = nil) {
        SecItemDelete(scoped([kSecClass: kSecClassKey, kSecAttrApplicationTag: Data(tag.utf8)]))
        SecItemDelete(scoped([kSecClass: kSecClassCertificate, kSecAttrLabel: tag]))
        // Removing a context must take its certificate with it, whatever label
        // it happens to carry.
        if let certPEM, let leaf = try? certificates(fromPEM: certPEM).first {
            SecItemDelete(scoped([kSecClass: kSecClassCertificate, kSecValueRef: leaf]))
        }
    }

    /// The value the keychain matches a certificate against when it looks for
    /// that certificate's private key.
    ///
    /// Security computes this itself and exposes it as the key's application
    /// label; that value is used when it is there. Computing one instead —
    /// SHA-1 of the DER public key, which is the documented derivation — is
    /// right for RSA and wrong for EC, where it disagrees with Security's and
    /// the insert fails with "the specified item is no longer valid", a message
    /// that describes nothing about the cause.
    static func publicKeyHash(of privateKey: SecKey) throws -> Data {
        if let attributes = SecKeyCopyAttributes(privateKey) as? [CFString: Any],
           let label = attributes[kSecAttrApplicationLabel] as? Data {
            return label
        }
        guard let pub = SecKeyCopyPublicKey(privateKey) else {
            throw Error.badPrivateKey("no public key could be derived")
        }
        var err: Unmanaged<CFError>?
        guard let der = SecKeyCopyExternalRepresentation(pub, &err) as Data? else {
            throw Error.badPrivateKey("public key has no external representation")
        }
        return Data(Insecure.SHA1.hash(data: der))
    }

    /// Which keychain the item goes in.
    ///
    /// iOS has only the data-protection keychain, and that is where the shipped
    /// app stores these. macOS has both, and the data-protection one requires a
    /// `keychain-access-groups` entitlement, which the command-line harness that
    /// exercises this code against real clusters cannot carry — so on macOS it
    /// is asked for the file keychain explicitly. Same items, same identity;
    /// only the store differs, and only off-device.
    static func scoped(_ query: [CFString: Any]) -> CFDictionary {
        var q = query
        #if os(macOS)
        q[kSecUseDataProtectionKeychain] = false
        #endif
        return q as CFDictionary
    }
}

/// Just enough DER to strip the two wrappers `SecKeyCreateWithData` will not take.
public enum DER {
    /// SEC1 `ECPrivateKey ::= SEQUENCE { version, privateKey OCTET STRING, [0] params, [1] publicKey BIT STRING }`
    /// → the X9.63 form Security wants: `04 || X || Y || d`.
    static func ecPrivateKeyFromSEC1(_ der: Data) throws -> Data {
        var p = Parser(der)
        try p.enter(0x30)
        _ = try p.read(0x02)                     // version
        let priv = try p.read(0x04)              // privateKey
        var pub: Data?
        while let tag = p.peek() {
            let body = try p.readAny()
            if tag == 0xA1 {                     // [1] publicKey
                var inner = Parser(body)
                pub = try inner.read(0x03).dropFirst()   // BIT STRING, drop unused-bits byte
            }
        }
        guard let pub else { throw Identity.Error.badPrivateKey("EC key carries no public point") }
        return pub + priv
    }

    /// PKCS#8 `PrivateKeyInfo ::= SEQUENCE { version, AlgorithmIdentifier, privateKey OCTET STRING }`
    /// → the inner key, and whether the algorithm is EC.
    static func unwrapPKCS8(_ der: Data) throws -> (inner: Data, isEC: Bool) {
        var p = Parser(der)
        try p.enter(0x30)
        _ = try p.read(0x02)                     // version
        let alg = try p.read(0x30)               // AlgorithmIdentifier
        let inner = try p.read(0x04)             // privateKey
        // 1.2.840.10045.2.1 — id-ecPublicKey
        let ecOID = Data([0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01])
        return (inner, alg.range(of: ecOID) != nil)
    }

    public struct Parser {
        let bytes: Data
        var i: Data.Index
        public init(_ d: Data) { bytes = d; i = d.startIndex }

        public func peek() -> UInt8? { i < bytes.endIndex ? bytes[i] : nil }

        public mutating func enter(_ tag: UInt8) throws {
            let body = try read(tag)
            // Re-base onto the contents of the constructed value.
            self = Parser(body)
        }

        public mutating func read(_ tag: UInt8) throws -> Data {
            guard i < bytes.endIndex, bytes[i] == tag else {
                throw Identity.Error.badPrivateKey("expected DER tag 0x\(String(tag, radix: 16))")
            }
            return try readAny()
        }

        public mutating func readAny() throws -> Data {
            guard i < bytes.endIndex else { throw Identity.Error.badPrivateKey("truncated DER") }
            i = bytes.index(after: i)                       // tag
            guard i < bytes.endIndex else { throw Identity.Error.badPrivateKey("truncated DER length") }
            var len = Int(bytes[i]); i = bytes.index(after: i)
            if len & 0x80 != 0 {
                let n = len & 0x7F
                guard n > 0, n <= 4, bytes.index(i, offsetBy: n, limitedBy: bytes.endIndex) != nil else {
                    throw Identity.Error.badPrivateKey("unsupported DER length")
                }
                len = 0
                for _ in 0..<n { len = (len << 8) | Int(bytes[i]); i = bytes.index(after: i) }
            }
            guard let end = bytes.index(i, offsetBy: len, limitedBy: bytes.endIndex) else {
                throw Identity.Error.badPrivateKey("DER length runs past the end")
            }
            defer { i = end }
            return bytes[i..<end]
        }
    }
}
