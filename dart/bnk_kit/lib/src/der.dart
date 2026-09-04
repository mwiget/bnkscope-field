import 'dart:typed_data';

class DerException implements Exception {
  final String message;
  const DerException(this.message);
  @override
  String toString() => 'the certificate could not be read: $message';
}

/// Just enough DER to walk a certificate.
class DerParser {
  final Uint8List bytes;
  int _i = 0;

  DerParser(List<int> data)
      : bytes = data is Uint8List ? data : Uint8List.fromList(data);

  int? peek() => _i < bytes.length ? bytes[_i] : null;

  /// Enter a constructed value: the parser is re-based onto its contents.
  DerParser enter(int tag) => DerParser(read(tag));

  Uint8List read(int tag) {
    if (_i >= bytes.length || bytes[_i] != tag) {
      throw DerException('expected DER tag 0x${tag.toRadixString(16)}');
    }
    return readAny();
  }

  Uint8List readAny() {
    if (_i >= bytes.length) throw const DerException('truncated DER');
    _i++; // tag
    if (_i >= bytes.length) throw const DerException('truncated DER length');
    var len = bytes[_i++];
    if (len & 0x80 != 0) {
      final n = len & 0x7F;
      if (n == 0 || n > 4 || _i + n > bytes.length) {
        throw const DerException('unsupported DER length');
      }
      len = 0;
      for (var k = 0; k < n; k++) {
        len = (len << 8) | bytes[_i++];
      }
    }
    final end = _i + len;
    if (end > bytes.length) {
      throw const DerException('DER length runs past the end');
    }
    final out = Uint8List.sublistView(bytes, _i, end);
    _i = end;
    return out;
  }
}
