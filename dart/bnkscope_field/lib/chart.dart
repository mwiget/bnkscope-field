import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:bnk_engines/bnk_engines.dart';
import 'package:flutter/material.dart';

import 'theme.dart';
import 'widgets.dart';

/// One dashboard panel.
///
/// Drawn here rather than through a charting package: the panels need gaps
/// to stay gaps, a fixed domain where the quantity has one, a scrub readout
/// in the legend, and minute:second labels, and the painter that does those
/// four things is shorter than the configuration that would coax them out
/// of a library.
class ChartPanel extends StatefulWidget {
  final PanelId panel;
  final PanelData data;
  final double height;

  /// Whether this panel is currently filling the window.
  final bool isZoomed;

  /// Null when zooming is not offered: a zoomed panel with no way out would
  /// be a trap.
  final VoidCallback? onToggleZoom;

  const ChartPanel(
      {super.key, required this.panel, required this.data, this.height = 182, this.isZoomed = false, this.onToggleZoom});

  @override
  State<ChartPanel> createState() => _ChartPanelState();
}

class _ChartPanelState extends State<ChartPanel> {
  DateTime? _scrubbed;

  List<String> get _names => widget.data.names;

  /// Colour follows the series' position in the sorted name list, so a line
  /// that stops reporting for a scrape keeps its colour when it returns.
  Color _color(String name) => Tokens.seriesColor(_names.indexOf(name));

  /// The value each line held at the scrubbed instant, or its latest.
  double? _readout(String name) {
    final at = _scrubbed;
    final points = widget.data.lines[name];
    if (at == null || points == null) return widget.data.latest(name);
    Point? best;
    for (final p in points) {
      if (p.v == null) continue;
      if (best == null || (p.t.difference(at).abs() < best.t.difference(at).abs())) best = p;
    }
    return best?.v;
  }

  @override
  Widget build(BuildContext context) {
    final panel = widget.panel;
    final toggle = widget.onToggleZoom;
    return GestureDetector(
      // Double-tap on touch, double-click with a trackpad or mouse: the
      // gesture people already use to blow something up and put it back.
      onDoubleTap: toggle,
      child: Panel(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(panel.title, style: Tokens.text(widget.isZoomed ? 16 : 13.5, weight: FontWeight.w600)),
                const SizedBox(height: 3),
                Text(panel.unit, style: Tokens.mono(widget.isZoomed ? 11.5 : 10.5, color: Tokens.muted)),
              ]),
            ),
            if (toggle != null)
              // The double-tap does the same thing, but a gesture nobody can
              // see is a feature nobody finds.
              Tooltip(
                message: widget.isZoomed ? 'Collapse ${panel.title}' : 'Expand ${panel.title}',
                child: InkWell(
                  onTap: toggle,
                  borderRadius: BorderRadius.circular(7),
                  child: Container(
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                      color: Tokens.secondary,
                      borderRadius: BorderRadius.circular(7),
                      border: Border.all(color: Tokens.border),
                    ),
                    child: Icon(widget.isZoomed ? Icons.close_fullscreen : Icons.open_in_full, size: 13, color: Tokens.muted),
                  ),
                ),
              ),
          ]),
          const SizedBox(height: 10),
          // Always present for two or more lines, so identity never rests on
          // colour alone. It doubles as the readout while scrubbing.
          Wrap(spacing: 12, runSpacing: 4, children: [
            for (final name in _names.take(6))
              _LegendChip(name: name, color: _color(name), value: _readout(name).let(panel.format.call)),
          ]),
          const SizedBox(height: 10),
          SizedBox(
            height: widget.height,
            child: LayoutBuilder(builder: (context, constraints) {
              final layout = _ChartLayout(widget.data, panel, Size(constraints.maxWidth, constraints.maxHeight));
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanStart: (d) => setState(() => _scrubbed = layout.timeAt(d.localPosition.dx)),
                onPanUpdate: (d) => setState(() => _scrubbed = layout.timeAt(d.localPosition.dx)),
                onPanEnd: (_) => setState(() => _scrubbed = null),
                onPanCancel: () => setState(() => _scrubbed = null),
                child: CustomPaint(
                  size: Size(constraints.maxWidth, constraints.maxHeight),
                  painter: _ChartPainter(layout, _color, _scrubbed),
                ),
              );
            }),
          ),
        ]),
      ),
    );
  }
}

extension _Let<T extends Object> on T? {
  R? let<R>(R Function(T) f) {
    final self = this;
    return self == null ? null : f(self);
  }
}

class _LegendChip extends StatelessWidget {
  final String name;
  final Color color;
  final String? value;
  const _LegendChip({required this.name, required this.color, this.value});

  @override
  Widget build(BuildContext context) => ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 132, maxWidth: 260),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 9, height: 2.5, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2))),
          const SizedBox(width: 6),
          Flexible(child: Text(name, style: Tokens.mono(10.5, color: Tokens.muted), maxLines: 1, overflow: TextOverflow.ellipsis)),
          if (value != null) ...[
            const SizedBox(width: 6),
            Text(value!, style: Tokens.mono(10.5, weight: FontWeight.w600), maxLines: 1),
          ],
        ]),
      );
}

/// Where the plot sits and how time and value map onto it.
class _ChartLayout {
  final PanelData data;
  final PanelId panel;
  final Size size;
  late final Rect plot;
  late final DateTime tMin;
  late final DateTime tMax;
  late final double yMin;
  late final double yMax;

  static const leftGutter = 46.0;
  static const bottomGutter = 16.0;

  _ChartLayout(this.data, this.panel, this.size) {
    plot = Rect.fromLTRB(leftGutter, 4, size.width - 6, size.height - bottomGutter);
    DateTime? lo, hi;
    double? vLo, vHi;
    for (final line in data.lines.values) {
      for (final p in line) {
        if (lo == null || p.t.isBefore(lo)) lo = p.t;
        if (hi == null || p.t.isAfter(hi)) hi = p.t;
        final v = p.v;
        if (v == null || v.isNaN || v.isInfinite) continue;
        if (vLo == null || v < vLo) vLo = v;
        if (vHi == null || v > vHi) vHi = v;
      }
    }
    tMin = lo ?? DateTime.now();
    tMax = (hi == null || hi == tMin) ? tMin.add(const Duration(seconds: 1)) : hi;
    final fixed = panel.yDomain;
    if (fixed != null) {
      yMin = fixed.min;
      yMax = fixed.max;
    } else {
      // Automatic, and including zero: a line hovering at 400 should not
      // fill the panel as if it were swinging wildly. A panel whose lines
      // are all zero gets a unit axis rather than a span of nothing, which
      // would print the same label at every tick.
      final low = math.min(0.0, vLo ?? 0);
      var high = math.max(vHi ?? 0, low + 1);
      high = high + (high - low) * 0.05;
      yMin = low;
      yMax = high;
    }
  }

  double x(DateTime t) =>
      plot.left + plot.width * (t.difference(tMin).inMicroseconds / tMax.difference(tMin).inMicroseconds);

  double y(double v) => plot.bottom - plot.height * ((v - yMin) / (yMax - yMin));

  DateTime timeAt(double dx) {
    final f = ((dx - plot.left) / plot.width).clamp(0.0, 1.0);
    return tMin.add(Duration(microseconds: (tMax.difference(tMin).inMicroseconds * f).round()));
  }
}

class _ChartPainter extends CustomPainter {
  final _ChartLayout layout;
  final Color Function(String) color;
  final DateTime? scrubbed;
  _ChartPainter(this.layout, this.color, this.scrubbed);

  @override
  void paint(Canvas canvas, Size size) {
    final plot = layout.plot;
    final grid = Paint()
      ..color = Tokens.border.withValues(alpha: 0.55)
      ..strokeWidth = 1;

    // Four value marks, three time marks: the fourth time mark lands on the
    // plot's right edge and its label is clipped.
    for (final v in _niceTicks(layout.yMin, layout.yMax, 4)) {
      final y = layout.y(v);
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), grid);
      _label(canvas, layout.panel.format(v), Offset(plot.left - 6, y), alignRight: true);
    }
    for (var i = 1; i <= 3; i++) {
      final t = layout.tMin.add(layout.tMax.difference(layout.tMin) * i ~/ 4);
      final x = layout.x(t);
      canvas.drawLine(Offset(x, plot.top), Offset(x, plot.bottom), grid);
      // Minutes and seconds only. The window is half an hour at most, so the
      // hour is the same on every label and only costs width.
      final local = t.toLocal();
      _label(canvas, '${_two(local.minute)}:${_two(local.second)}', Offset(x, plot.bottom + 3), below: true);
    }

    canvas.save();
    canvas.clipRect(plot);
    final baseline = layout.y(layout.yMin.clamp(layout.yMin, 0.0) == layout.yMin && layout.yMin <= 0 ? 0.0 : layout.yMin);
    for (final name in layout.data.names) {
      final c = color(name);
      for (final run in _segments(layout.data.lines[name] ?? const [])) {
        final pts = [for (final p in run) Offset(layout.x(p.$1), layout.y(p.$2))];
        final line = _monotone(pts);
        final area = Path.from(line)
          ..lineTo(pts.last.dx, baseline)
          ..lineTo(pts.first.dx, baseline)
          ..close();
        canvas.drawPath(area, Paint()..color = c.withValues(alpha: 0.13));
        canvas.drawPath(
            line,
            Paint()
              ..color = c
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2
              ..strokeJoin = StrokeJoin.round
              ..strokeCap = StrokeCap.round);
        if (pts.length == 1) canvas.drawCircle(pts.first, 2, Paint()..color = c);
      }
    }
    final at = scrubbed;
    if (at != null) {
      final x = layout.x(at);
      final dash = Paint()
        ..color = Tokens.fg.withValues(alpha: 0.35)
        ..strokeWidth = 1;
      for (var y = plot.top; y < plot.bottom; y += 6) {
        canvas.drawLine(Offset(x, y), Offset(x, math.min(y + 3, plot.bottom)), dash);
      }
    }
    canvas.restore();
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  void _label(Canvas canvas, String text, Offset at, {bool alignRight = false, bool below = false}) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: Tokens.mono(9.5, color: Tokens.faint)),
      textDirection: TextDirection.ltr,
    )..layout();
    final dx = alignRight ? at.dx - painter.width : at.dx - painter.width / 2;
    final dy = below ? at.dy : at.dy - painter.height / 2;
    painter.paint(canvas, Offset(dx, dy));
  }

  /// Runs of consecutive measured points. A break splits the line into two
  /// runs, and each run is drawn on its own, which is the whole point: the
  /// gap has to stay a gap.
  static List<List<(DateTime, double)>> _segments(List<Point> points) {
    final out = <List<(DateTime, double)>>[];
    var run = <(DateTime, double)>[];
    for (final p in points) {
      final v = p.v;
      if (v != null && !v.isNaN && !v.isInfinite) {
        run.add((p.t, v));
      } else if (run.isNotEmpty) {
        out.add(run);
        run = [];
      }
    }
    if (run.isNotEmpty) out.add(run);
    return out;
  }

  /// Fritsch–Carlson monotone cubic interpolation: smooth, and it never
  /// overshoots a sample, so a line that idles at 97% stays under 100.
  static Path _monotone(List<Offset> p) {
    final path = Path();
    if (p.isEmpty) return path;
    path.moveTo(p.first.dx, p.first.dy);
    if (p.length == 1) return path;
    final n = p.length;
    final dx = List<double>.generate(n - 1, (i) => p[i + 1].dx - p[i].dx);
    final dy = List<double>.generate(n - 1, (i) => p[i + 1].dy - p[i].dy);
    final m = List<double>.generate(n - 1, (i) => dx[i] == 0 ? 0 : dy[i] / dx[i]);
    final t = List<double>.filled(n, 0);
    t[0] = m[0];
    t[n - 1] = m[n - 2];
    for (var i = 1; i < n - 1; i++) {
      t[i] = (m[i - 1] * m[i] <= 0) ? 0 : (m[i - 1] + m[i]) / 2;
    }
    for (var i = 0; i < n - 1; i++) {
      if (m[i] == 0) {
        t[i] = 0;
        t[i + 1] = 0;
        continue;
      }
      final a = t[i] / m[i];
      final b = t[i + 1] / m[i];
      final s = a * a + b * b;
      if (s > 9) {
        final tau = 3 / math.sqrt(s);
        t[i] = tau * a * m[i];
        t[i + 1] = tau * b * m[i];
      }
    }
    for (var i = 0; i < n - 1; i++) {
      final h = dx[i];
      path.cubicTo(p[i].dx + h / 3, p[i].dy + t[i] * h / 3, p[i + 1].dx - h / 3, p[i + 1].dy - t[i + 1] * h / 3,
          p[i + 1].dx, p[i + 1].dy);
    }
    return path;
  }

  static List<double> _niceTicks(double lo, double hi, int count) {
    final range = hi - lo;
    if (range <= 0) return [lo];
    final rough = range / (count - 1);
    final magnitude = math.pow(10, (math.log(rough) / math.ln10).floor()).toDouble();
    final residual = rough / magnitude;
    final step = (residual >= 5 ? 5 : residual >= 2 ? 2 : 1) * magnitude;
    final out = <double>[];
    for (var v = (lo / step).ceil() * step; v <= hi + step * 1e-6 && out.length < 12; v += step) {
      out.add(v);
    }
    return out;
  }

  @override
  bool shouldRepaint(_ChartPainter old) => true;
}

/// A headline number over the panels.
class Tile extends StatelessWidget {
  final String label;
  final String value;
  final String unit;
  final String sub;
  const Tile({super.key, required this.label, required this.value, this.unit = '', required this.sub});

  @override
  Widget build(BuildContext context) => Panel(
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 13),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: Tokens.text(11, weight: FontWeight.w600, color: Tokens.muted).copyWith(letterSpacing: 0.55)),
          const SizedBox(height: 6),
          Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(value, style: Tokens.mono(26, weight: FontWeight.w600).copyWith(fontFeatures: const [ui.FontFeature.tabularFigures()]), maxLines: 1),
              ),
            ),
            if (unit.isNotEmpty) ...[
              const SizedBox(width: 5),
              Text(unit, style: Tokens.mono(12, color: Tokens.muted)),
            ],
          ]),
          const SizedBox(height: 6),
          Text(sub, style: Tokens.mono(10.5, color: Tokens.faint), maxLines: 1, overflow: TextOverflow.ellipsis),
        ]),
      );
}
