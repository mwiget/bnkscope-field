/// Kubernetes writes RFC 3339, usually to the second but with fractional
/// seconds on some resources and nanoseconds on log timestamps.
class Rfc3339 {
  static final _shape =
      RegExp(r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?(?:Z|[+-]\d\d:\d\d)$');

  /// `null` for anything that is not a full timestamp. A bare date is not
  /// one: a log line that happens to start with a date is text.
  static DateTime? parse(String s) =>
      _shape.hasMatch(s) ? DateTime.tryParse(s)?.toUtc() : null;
}
