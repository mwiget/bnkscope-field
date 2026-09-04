/// How BNK names the objects it reports counters for.
class F5Names {
  /// A virtual server or pool as it is worth plotting.
  ///
  /// The full name carries the address it listens on,
  /// `scn-cwatch-scn-cwatch-gateway-203.0.113.105-http-80-vs`, which is the
  /// least identifying part of it and the widest. Drop the address and the
  /// protocol and port that follow it, and the `-vs` / `-pool` suffix. What is
  /// left is kept whole: trimming further would merge two pools of one gateway
  /// into a single line, which is exactly the comparison a pool panel is for.
  static String shortObjectName(String name) {
    final parts = name.split('-');
    final i = parts.indexWhere(looksLikeIPv4);
    if (i >= 0) {
      var drop = 1;
      const protocols = {'tcp', 'udp', 'http', 'https', 'sctp'};
      if (i + drop < parts.length && protocols.contains(parts[i + drop])) drop++;
      if (i + drop < parts.length && int.tryParse(parts[i + drop]) != null) {
        drop++;
      }
      parts.removeRange(i, i + drop > parts.length ? parts.length : i + drop);
    }
    if (parts.isNotEmpty && (parts.last == 'vs' || parts.last == 'pool')) {
      parts.removeLast();
    }
    final short = parts.join('-');
    return short.isEmpty ? name : short;
  }

  static final _digits = RegExp(r'^[0-9]+$');

  static bool looksLikeIPv4(String part) {
    final octets = part.split('.');
    if (octets.length != 4) return false;
    return octets.every((o) =>
        o.isNotEmpty && _digits.hasMatch(o) && (int.tryParse(o) ?? 256) < 256);
  }
}
