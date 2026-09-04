import 'dart:convert';
import 'dart:typed_data';

/// PEM is how kubeconfigs carry certificates and keys. The TLS stack takes
/// PEM directly, so nothing here converts a key; this is for reading what is
/// inside a certificate.
class Pem {
  static final _notBase64 = RegExp(r'[^A-Za-z0-9+/=]');

  /// Every DER block carrying [label], in file order.
  static List<Uint8List> blocks(List<int> pem, String label) {
    final String text;
    try {
      text = utf8.decode(pem);
    } on FormatException {
      return const [];
    }
    final begin = '-----BEGIN $label-----';
    final end = '-----END $label-----';
    final out = <Uint8List>[];
    var from = 0;
    while (true) {
      final b = text.indexOf(begin, from);
      if (b < 0) break;
      final bodyStart = b + begin.length;
      final e = text.indexOf(end, bodyStart);
      if (e < 0) break;
      final body = text.substring(bodyStart, e).replaceAll(_notBase64, '');
      try {
        out.add(base64.decode(base64.normalize(body)));
      } on FormatException {
        // Skip a block that is not base64, as the Swift original does.
      }
      from = e + end.length;
    }
    return out;
  }
}
