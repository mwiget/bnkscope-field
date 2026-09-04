/// Whether an address is one the device reaches over its own local network.
///
/// iOS and macOS gate the local subnet behind a per-app permission, and a
/// denial arrives as the same error a genuinely offline device reports. The
/// two need opposite fixes: one is "join a network", the other is "grant this
/// app Local Network access". Nothing in the error separates them, so the
/// address does.
class Net {
  /// RFC 1918, loopback, link-local, and mDNS names.
  static bool isLocal(String host) {
    var name = host.toLowerCase();
    if (name.startsWith('[')) name = name.substring(1);
    if (name.endsWith(']')) name = name.substring(0, name.length - 1);
    if (name == 'localhost' || name.endsWith('.local')) return true;
    if (name == '::1' || name.startsWith('fe80:')) return true;

    final parts = name.split('.');
    if (parts.length != 4) return false;
    final octets = <int>[];
    for (final part in parts) {
      if (part.isEmpty || part.length > 3) return false;
      final value = int.tryParse(part);
      if (value == null || value < 0 || value > 255) return false;
      octets.add(value);
    }
    return switch ((octets[0], octets[1])) {
      (10, _) => true, // 10.0.0.0/8
      (127, _) => true, // loopback
      (169, 254) => true, // link-local
      (172, final b) when b >= 16 && b <= 31 => true, // 172.16.0.0/12
      (192, 168) => true, // 192.168.0.0/16
      _ => false,
    };
  }
}
