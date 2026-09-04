import 'dart:convert';
import 'dart:typed_data';

import 'der.dart';
import 'pem.dart';

/// The few fields of an X.509 certificate worth putting on a screen.
///
/// Parsed from DER here rather than through a platform library, so that the
/// answer is the same on every platform. Expiry is the single most useful
/// fact about a lab certificate, so it is worth the ASN.1.
class Certificate {
  final String? subject;
  final String? issuer;
  final DateTime notBefore;
  final DateTime notAfter;

  const Certificate({
    required this.subject,
    required this.issuer,
    required this.notBefore,
    required this.notAfter,
  });

  bool get isExpired => notAfter.isBefore(DateTime.now());

  int get daysRemaining => notAfter.difference(DateTime.now()).inDays;

  /// The first certificate in a PEM bundle.
  static Certificate firstInPem(List<int> pem) {
    final blocks = Pem.blocks(pem, 'CERTIFICATE');
    if (blocks.isEmpty) {
      throw const DerException('no CERTIFICATE block in the PEM data');
    }
    return Certificate.fromDer(blocks.first);
  }

  /// ```
  /// Certificate     ::= SEQUENCE { tbsCertificate, signatureAlgorithm, signature }
  /// TBSCertificate  ::= SEQUENCE { [0] version, serialNumber, signature,
  ///                                issuer, validity, subject, ... }
  /// Validity        ::= SEQUENCE { notBefore Time, notAfter Time }
  /// ```
  factory Certificate.fromDer(List<int> der) {
    final certificate = DerParser(der).enter(0x30);
    final tbs = DerParser(certificate.read(0x30));
    if (tbs.peek() == 0xA0) tbs.readAny(); // [0] version, absent in v1
    tbs.read(0x02); // serialNumber
    tbs.read(0x30); // signature algorithm
    final issuerDer = tbs.read(0x30); // issuer Name
    final validity = DerParser(tbs.read(0x30));
    final subjectDer = tbs.read(0x30); // subject Name
    return Certificate(
      notBefore: _time(validity),
      notAfter: _time(validity),
      issuer: commonName(issuerDer),
      subject: commonName(subjectDer),
    );
  }

  static final _utcTime =
      RegExp(r'^(\d\d)(\d\d)(\d\d)(\d\d)(\d\d)(\d\d)?(Z|[+-]\d{4})$');
  static final _generalizedTime = RegExp(
      r'^(\d{4})(\d\d)(\d\d)(\d\d)(\d\d)(\d\d)?(?:[.,]\d+)?(Z|[+-]\d{4})$');

  /// `Time ::= UTCTime | GeneralizedTime`: two digits of year or four. RFC
  /// 5280 reads a two-digit year of 50 or more as the twentieth century.
  static DateTime _time(DerParser parser) {
    final tag = parser.peek();
    if (tag == null) throw const DerException('truncated validity');
    final text = ascii.decode(parser.readAny(), allowInvalid: true);
    final utc = tag == 0x17;
    final m = (utc ? _utcTime : _generalizedTime).firstMatch(text);
    if (m == null) {
      throw DerException('unreadable certificate time "$text"');
    }
    var year = int.parse(m[1]!);
    if (utc) year += year >= 50 ? 1900 : 2000;
    var date = DateTime.utc(year, int.parse(m[2]!), int.parse(m[3]!),
        int.parse(m[4]!), int.parse(m[5]!), int.parse(m[6] ?? '0'));
    final zone = m[7]!;
    if (zone != 'Z') {
      final offset = Duration(
          hours: int.parse(zone.substring(1, 3)),
          minutes: int.parse(zone.substring(3, 5)));
      date = zone.startsWith('+') ? date.subtract(offset) : date.add(offset);
    }
    return date;
  }

  /// The commonName out of an RDNSequence.
  ///
  /// Walked by looking for the CN object identifier rather than decoding the
  /// whole name: a distinguished name nests SET inside SEQUENCE inside
  /// SEQUENCE, and the only field being shown is this one.
  static String? commonName(Uint8List name) {
    const cnOid = [0x06, 0x03, 0x55, 0x04, 0x03];
    final at = _indexOf(name, cnOid);
    if (at < 0) return null;
    try {
      final body = DerParser(name.sublist(at + cnOid.length)).readAny();
      return utf8.decode(body, allowMalformed: true);
    } on DerException {
      return null;
    }
  }

  static int _indexOf(Uint8List haystack, List<int> needle) {
    outer:
    for (var i = 0; i + needle.length <= haystack.length; i++) {
      for (var j = 0; j < needle.length; j++) {
        if (haystack[i + j] != needle[j]) continue outer;
      }
      return i;
    }
    return -1;
  }
}
