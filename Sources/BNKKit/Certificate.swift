import Foundation

/// The few fields of an X.509 certificate worth putting on a screen.
///
/// Parsed from DER here rather than through Security, because the framework has
/// no public way to read a certificate's validity dates on iOS —
/// `SecCertificateCopyValues` is macOS only, and `CopySubjectSummary` gives a
/// subject and nothing else. Expiry is the single most useful fact about a lab
/// certificate, so it is worth the ASN.1.
public struct Certificate: Sendable, Equatable {
    public let subject: String?
    public let issuer: String?
    public let notBefore: Date
    public let notAfter: Date

    public var isExpired: Bool { notAfter < Date() }

    public var daysRemaining: Int {
        Calendar.current.dateComponents([.day], from: Date(), to: notAfter).day ?? 0
    }

    /// The first certificate in a PEM bundle.
    public static func first(inPEM pem: Data) throws -> Certificate {
        guard let der = Identity.pemBlocks(pem, label: "CERTIFICATE").first else {
            throw Identity.Error.noPEMBlock("CERTIFICATE")
        }
        return try Certificate(der: der)
    }

    /// ```
    /// Certificate     ::= SEQUENCE { tbsCertificate, signatureAlgorithm, signature }
    /// TBSCertificate  ::= SEQUENCE { [0] version, serialNumber, signature,
    ///                                issuer, validity, subject, ... }
    /// Validity        ::= SEQUENCE { notBefore Time, notAfter Time }
    /// ```
    public init(der: Data) throws {
        var certificate = DER.Parser(der)
        try certificate.enter(0x30)                  // Certificate
        var tbs = DER.Parser(try certificate.read(0x30))
        if tbs.peek() == 0xA0 { _ = try tbs.readAny() }   // [0] version, absent in v1
        _ = try tbs.read(0x02)                       // serialNumber
        _ = try tbs.read(0x30)                       // signature algorithm
        let issuerDER = try tbs.read(0x30)           // issuer Name
        var validity = DER.Parser(try tbs.read(0x30))
        let subjectDER = try tbs.read(0x30)          // subject Name

        self.notBefore = try Certificate.time(&validity)
        self.notAfter = try Certificate.time(&validity)
        self.issuer = Certificate.commonName(in: issuerDER)
        self.subject = Certificate.commonName(in: subjectDER)
    }

    /// `Time ::= UTCTime | GeneralizedTime` — two digits of year or four.
    static func time(_ parser: inout DER.Parser) throws -> Date {
        guard let tag = parser.peek() else { throw Identity.Error.badPrivateKey("truncated validity") }
        let body = try parser.readAny()
        let text = String(decoding: body, as: UTF8.self)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = tag == 0x17 ? "yyMMddHHmmssX" : "yyyyMMddHHmmssX"
        guard let date = formatter.date(from: text) else {
            throw Identity.Error.badPrivateKey("unreadable certificate time \"\(text)\"")
        }
        return date
    }

    /// The commonName out of an RDNSequence.
    ///
    /// Walked by looking for the CN object identifier rather than decoding the
    /// whole name: a distinguished name nests SET inside SEQUENCE inside
    /// SEQUENCE, and the only field being shown is this one.
    static func commonName(in name: Data) -> String? {
        let cnOID = Data([0x06, 0x03, 0x55, 0x04, 0x03])
        guard let oid = name.range(of: cnOID) else { return nil }
        var value = DER.Parser(Data(name[oid.upperBound...]))
        guard let body = try? value.readAny() else { return nil }
        return String(decoding: body, as: UTF8.self)
    }
}
