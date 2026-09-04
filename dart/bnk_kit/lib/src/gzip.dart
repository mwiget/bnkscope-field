import 'dart:io';
import 'dart:typed_data';

enum GzipFailure {
  notGzip('the body does not start with a gzip magic number'),
  truncatedHeader('the gzip header is truncated'),
  inflate('the gzip body did not inflate');

  final String description;
  const GzipFailure(this.description);
}

class GzipException implements Exception {
  final GzipFailure failure;
  const GzipException(this.failure);
  @override
  String toString() => failure.description;
}

/// gzip inflation.
///
/// The exporter gzips its exposition text roughly twenty-fold, 286 KB becomes
/// 14 KB, which is the difference between a scrape a tablet can afford every
/// two seconds and one it cannot, so this path is on by default rather than an
/// option. The header is checked here so that the three ways a body can be
/// wrong are reported apart.
class Gzip {
  static Uint8List inflate(List<int> data) {
    checkHeader(data);
    try {
      return Uint8List.fromList(gzip.decode(data));
    } on FormatException {
      throw const GzipException(GzipFailure.inflate);
    }
  }

  /// RFC 1952 §2.3: magic, method, flags, mtime, xfl, os, then the optional
  /// FEXTRA / FNAME / FCOMMENT / FHCRC fields the flag byte announces.
  /// Returns where the deflate body starts.
  static int checkHeader(List<int> b) {
    if (b.length <= 18) throw const GzipException(GzipFailure.truncatedHeader);
    if (b[0] != 0x1f || b[1] != 0x8b || b[2] != 0x08) {
      throw const GzipException(GzipFailure.notGzip);
    }
    final flags = b[3];
    var i = 10;
    void need(int n) {
      if (i + n > b.length) {
        throw const GzipException(GzipFailure.truncatedHeader);
      }
    }

    if (flags & 0x04 != 0) {
      // FEXTRA
      need(2);
      final xlen = b[i] | (b[i + 1] << 8);
      i += 2 + xlen;
    }
    if (flags & 0x08 != 0) i = _skipCString(b, i); // FNAME
    if (flags & 0x10 != 0) i = _skipCString(b, i); // FCOMMENT
    if (flags & 0x02 != 0) i += 2; // FHCRC
    if (i >= b.length - 8) {
      throw const GzipException(GzipFailure.truncatedHeader);
    }
    return i;
  }

  static int _skipCString(List<int> b, int start) {
    var i = start;
    while (i < b.length && b[i] != 0) {
      i++;
    }
    if (i >= b.length) throw const GzipException(GzipFailure.truncatedHeader);
    return i + 1;
  }
}
