import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// The bnkscope web UI's dark tokens, carried over unchanged so the two
/// read as one product.
///
/// Colour is a monitoring convention, not broadcast: green means data is
/// flowing, red means it is not. The brand red belongs to the mark and
/// nothing else.
class Tokens {
  static const bg = Color(0xFF111217);
  static const card = Color(0xFF161A1F);
  static const border = Color(0xFF303740);
  static const fg = Color(0xFFCCCCDC);
  static const muted = Color(0xFF7C7C9C);
  static const faint = Color(0xFF5C6270);
  static const secondary = Color(0xFF1E2028);
  static const mutedBg = Color(0xFF22252B);

  static const primary = Color(0xFF2563EB);
  static const ember = Color(0xFFFF6A00);
  static const deep = Color(0xFFE4002B);

  /// The logo's red. It belongs to the mark, and to nothing else.
  static const brand = Color(0xFFFF3355);

  static const ok = Color(0xFF10B981);
  static const warn = Color(0xFFF59E0B);
  static const bad = Color(0xFFEF4444);

  /// The active row's text, a touch brighter than [fg].
  static const activeFg = Color(0xFFDFE7F7);

  /// The dot of a cluster that cannot be reached.
  static const deadDot = Color(0xFF4B515E);

  /// Series colours, assigned in this fixed order and never cycled. The
  /// three status hues are deliberately absent: amber, red and green mean
  /// something here, and a series that borrows one lies about its state.
  static const series = [
    Color(0xFF3B82F6), // blue
    Color(0xFF0D9488), // teal
    Color(0xFF8B5CF6), // violet
    Color(0xFFDB2777), // pink
    Color(0xFF0891B2), // cyan
  ];

  static Color seriesColor(int index) => index < series.length ? series[index] : muted;

  static const monoFamily = 'Menlo';
  static const monoFallback = ['SF Mono', 'Consolas', 'DejaVu Sans Mono', 'Roboto Mono', 'monospace'];

  static TextStyle mono(double size, {FontWeight weight = FontWeight.w400, Color color = fg}) => TextStyle(
      fontFamily: monoFamily, fontFamilyFallback: monoFallback, fontSize: size, fontWeight: weight, color: color);

  static TextStyle text(double size, {FontWeight weight = FontWeight.w400, Color color = fg}) =>
      TextStyle(fontSize: size, fontWeight: weight, color: color);

  static ThemeData get theme {
    final base = ThemeData(brightness: Brightness.dark, useMaterial3: true);
    return base.copyWith(
      scaffoldBackgroundColor: bg,
      canvasColor: bg,
      colorScheme: const ColorScheme.dark(
        primary: primary,
        onPrimary: Colors.white,
        surface: card,
        onSurface: fg,
        error: bad,
        outline: border,
      ),
      dividerColor: border,
      textTheme: base.textTheme.apply(bodyColor: fg, displayColor: fg),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: primary,
          foregroundColor: Colors.white,
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          textStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: fg,
          backgroundColor: secondary,
          side: const BorderSide(color: border),
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          textStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: fg, visualDensity: VisualDensity.compact),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: border)),
        titleTextStyle: text(16, weight: FontWeight.w600),
        contentTextStyle: text(13, color: muted),
      ),
      drawerTheme: const DrawerThemeData(backgroundColor: card),
      progressIndicatorTheme: const ProgressIndicatorThemeData(color: primary),
      splashFactory: NoSplash.splashFactory,
    );
  }
}

/// The bnkscope mark: a heptagonal scope with a waveform across it. Traced
/// from `frontend-v2/public/icons/bnkscope-small.svg` so the two stay the
/// same shape.
class BNKMark extends StatelessWidget {
  final double size;
  const BNKMark({super.key, this.size = 28});

  @override
  Widget build(BuildContext context) =>
      SizedBox(width: size, height: size, child: CustomPaint(painter: _MarkPainter()));
}

class _MarkPainter extends CustomPainter {
  static final bezel = Path()
    ..moveTo(32, 9.6)
    ..lineTo(49.98, 18.26)
    ..lineTo(54.42, 37.72)
    ..lineTo(41.98, 53.32)
    ..lineTo(22.02, 53.32)
    ..lineTo(9.58, 37.72)
    ..lineTo(14.02, 18.26)
    ..close();

  static final beam = () {
    const pts = [
      (15.0, 33.0), (18.0, 32.92), (19.5, 30.7), (21.0, 26.58), (22.5, 26.39), (24.5, 28.48), (27.0, 32.82),
      (29.0, 35.74), (31.0, 37.01), (33.0, 36.44), (35.0, 34.63), (37.0, 32.53), (39.0, 31.03), (41.0, 30.6),
      (43.0, 31.2), (45.0, 32.39), (47.0, 33.59), (48.0, 34.03),
    ];
    final p = Path()..moveTo(pts[0].$1, pts[0].$2);
    for (final pt in pts.skip(1)) {
      p.lineTo(pt.$1, pt.$2);
    }
    return p;
  }();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 64, size.height / 64);
    canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(2, 2, 60, 60), const Radius.circular(14)),
        Paint()..color = const Color(0xFF15181D));
    canvas.drawPath(bezel, Paint()..color = const Color(0xFF0A0C10));
    canvas.save();
    canvas.clipPath(bezel);
    canvas.drawPath(
        beam,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..shader = ui.Gradient.linear(const Offset(12, 0), const Offset(52, 0),
              const [Tokens.brand, Tokens.brand, Tokens.ember], const [0, 0.5, 1]));
    canvas.restore();
    canvas.drawPath(
        bezel,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.6
          ..strokeJoin = StrokeJoin.round
          ..color = Tokens.deep);
  }

  @override
  bool shouldRepaint(_MarkPainter old) => false;
}
