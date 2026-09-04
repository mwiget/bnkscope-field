import 'dart:convert';

/// One sample from an exposition-format scrape.
class Sample {
  final String name;
  final Map<String, String> labels;
  final double value;

  const Sample(this.name, this.labels, this.value);

  /// The series key: the name plus its labels, sorted. Two scrapes of the same
  /// series produce the same key, which is what makes a rate computable.
  String get seriesKey {
    final keys = labels.keys.toList()..sort();
    final l = keys.map((k) => '$k=${labels[k]}').join(',');
    return l.isEmpty ? name : '$name{$l}';
  }

  @override
  bool operator ==(Object other) =>
      other is Sample &&
      other.name == name &&
      other.value == value &&
      other.labels.length == labels.length &&
      labels.entries.every((e) => other.labels[e.key] == e.value);

  @override
  int get hashCode => Object.hash(name, value, labels.length);

  @override
  String toString() => '$seriesKey = $value';
}

/// A parser for the Prometheus text exposition format, 0.0.4.
///
/// Field parses scrapes itself because there is no Prometheus in the Direct
/// path: it holds the last two scrapes and derives rates from them, the same
/// arithmetic `rate()` would do server-side. Only what the exporter emits is
/// handled, gauges, no histograms or summaries, no exemplars, because that is
/// the whole of what it produces, and a parser that pretends to more than it
/// was tested against is a liability.
class PromText {
  static List<Sample> parse(String text) {
    final out = <Sample>[];
    for (final line in const LineSplitter().convert(text)) {
      final s = parseLine(line);
      if (s != null) out.add(s);
    }
    return out;
  }

  static List<Sample> parseBytes(List<int> data) =>
      parse(utf8.decode(data, allowMalformed: true));

  static Sample? parseLine(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) return null;

    final String name;
    var labels = const <String, String>{};
    final String rest;

    final open = trimmed.indexOf('{');
    if (open >= 0) {
      final close = trimmed.indexOf('}', open);
      if (close < 0) return null;
      name = trimmed.substring(0, open);
      labels = parseLabels(trimmed.substring(open + 1, close));
      rest = trimmed.substring(close + 1);
    } else {
      final sp = trimmed.indexOf(' ');
      if (sp < 0) return null;
      name = trimmed.substring(0, sp);
      rest = trimmed.substring(sp);
    }

    // value, then an optional timestamp the exporter never sets.
    final fields = rest.split(' ').where((f) => f.isNotEmpty);
    if (fields.isEmpty) return null;
    final value = parseValue(fields.first);
    if (value == null) return null;
    return Sample(name, labels, value);
  }

  static double? parseValue(String s) => switch (s) {
        'NaN' => double.nan,
        '+Inf' => double.infinity,
        '-Inf' => double.negativeInfinity,
        _ => double.tryParse(s),
      };

  /// `a="1",b="2"`: values are quoted and may contain escaped quotes and
  /// commas, so this walks the string rather than splitting on separators.
  static Map<String, String> parseLabels(String s) {
    final out = <String, String>{};
    final n = s.length;
    var i = 0;
    while (i < n) {
      while (i < n && (s[i] == ' ' || s[i] == ',')) {
        i++;
      }
      final eq = s.indexOf('=', i);
      if (eq < 0) break;
      final key = s.substring(i, eq).trim();
      var j = eq + 1;
      if (j >= n || s[j] != '"') break;
      j++;
      final value = StringBuffer();
      while (j < n && s[j] != '"') {
        if (s[j] == r'\' && j + 1 < n) {
          j++;
          switch (s[j]) {
            case 'n':
              value.write('\n');
            case 't':
              value.write('\t');
            default:
              value.write(s[j]);
          }
        } else {
          value.write(s[j]);
        }
        j++;
      }
      out[key] = value.toString();
      i = j < n ? j + 1 : n;
    }
    return out;
  }
}
