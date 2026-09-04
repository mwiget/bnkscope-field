import 'dart:convert';

/// A small, deterministic YAML emitter: block style, two-space indent, plain
/// scalars where they are unambiguous and JSON-quoted otherwise.
///
/// The `yaml` package parses and does not write, and everything this package
/// writes is either a kubeconfig it will parse again itself or an object a
/// person will read. Both want the same thing: stable output, no surprises.
String emitYaml(Object? value, {bool sortKeys = false}) {
  if ((value is Map && value.isNotEmpty) || (value is List && value.isNotEmpty)) {
    return "${_blockLines(value as Object, sortKeys).join('\n')}\n";
  }
  return '${_scalar(value)}\n';
}

List<String> _blockLines(Object value, bool sortKeys) {
  final lines = <String>[];
  if (value is Map) {
    final entries = [
      for (final e in value.entries) MapEntry(e.key.toString(), e.value)
    ];
    if (sortKeys) entries.sort((a, b) => a.key.compareTo(b.key));
    for (final e in entries) {
      final key = _scalar(e.key);
      final v = e.value;
      if (v is Map && v.isNotEmpty) {
        lines.add('$key:');
        lines.addAll(_blockLines(v, sortKeys).map((l) => '  $l'));
      } else if (v is List && v.isNotEmpty) {
        lines.add('$key:');
        lines.addAll(_blockLines(v, sortKeys));
      } else {
        lines.add('$key: ${_scalar(v)}');
      }
    }
  } else if (value is List) {
    for (final item in value) {
      if ((item is Map && item.isNotEmpty) || (item is List && item.isNotEmpty)) {
        final inner = _blockLines(item as Object, sortKeys);
        lines.add('- ${inner.first}');
        lines.addAll(inner.skip(1).map((l) => '  $l'));
      } else {
        lines.add('- ${_scalar(item)}');
      }
    }
  }
  return lines;
}

final _plainSafe = RegExp(r'^[A-Za-z_][A-Za-z0-9_./@+-]*$');
const _reserved = {
  'true', 'false', 'null', 'yes', 'no', 'on', 'off', 'y', 'n', '~',
  'nan', 'inf', 'infinity',
};

String _scalar(Object? v) {
  if (v == null) return 'null';
  if (v is bool) return v.toString();
  if (v is int) return v.toString();
  if (v is double) {
    if (v.isNaN) return '.nan';
    if (v.isInfinite) return v > 0 ? '.inf' : '-.inf';
    return v.toString();
  }
  if (v is Map) return '{}';
  if (v is List) return '[]';
  final s = v.toString();
  final plain = _plainSafe.hasMatch(s) &&
      !_reserved.contains(s.toLowerCase()) &&
      num.tryParse(s) == null;
  return plain ? s : jsonEncode(s);
}
