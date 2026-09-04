import 'time.dart';

/// Helpers for the hand-written decoders in this package. The models are
/// hand-written rather than generated: the full openapi schema is megabytes
/// and almost none of it is used.
typedef JsonMap = Map<String, dynamic>;

JsonMap? asMap(Object? v) => v is Map ? Map<String, dynamic>.from(v) : null;

JsonMap mapOrEmpty(Object? v) => asMap(v) ?? <String, dynamic>{};

List<T> asList<T>(Object? v, T Function(JsonMap) parse) {
  if (v is! List) return const [];
  return [
    for (final e in v)
      if (e is Map) parse(Map<String, dynamic>.from(e)),
  ];
}

List<T>? asListOrNull<T>(Object? v, T Function(JsonMap) parse) =>
    v is List ? asList(v, parse) : null;

List<String>? asStrings(Object? v) =>
    v is List ? [for (final e in v) if (e != null) e.toString()] : null;

Map<String, String>? asStringMap(Object? v) => v is Map
    ? {for (final e in v.entries) e.key.toString(): e.value?.toString() ?? ''}
    : null;

String? asString(Object? v) => v is String ? v : null;

bool? asBool(Object? v) => v is bool ? v : null;

int? asInt(Object? v) =>
    v is int ? v : v is num ? v.toInt() : v is String ? int.tryParse(v) : null;

DateTime? asDate(Object? v) => v is String ? Rfc3339.parse(v) : null;
