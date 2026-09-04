import 'package:flutter/material.dart';

import 'platform.dart';
import 'theme.dart';

class StatusDot extends StatelessWidget {
  final Color color;
  final bool glow;
  final double size;
  const StatusDot({super.key, required this.color, this.glow = false, this.size = 7});

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          boxShadow: glow ? [BoxShadow(color: color.withValues(alpha: 0.18), spreadRadius: 1.5)] : null,
        ),
      );
}

class Pill extends StatelessWidget {
  final String text;
  final Color color;
  const Pill(this.text, {super.key, this.color = Tokens.muted});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(99),
          border: Border.all(color: color.withValues(alpha: 0.2)),
        ),
        child: Text(text, style: Tokens.text(11, weight: FontWeight.w600, color: color), maxLines: 1),
      );
}

/// A small square tag, as the sidebar badges a cluster's roles.
class Tag extends StatelessWidget {
  final String text;
  final Color tone;
  const Tag(this.text, {super.key, this.tone = Tokens.muted});

  @override
  Widget build(BuildContext context) {
    final plain = tone == Tokens.muted;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: plain ? Tokens.mutedBg : tone.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: plain ? Tokens.border : tone.withValues(alpha: 0.25)),
      ),
      child: Text(text,
          style: Tokens.text(10, weight: FontWeight.w600, color: tone).copyWith(letterSpacing: 0.4), maxLines: 1),
    );
  }
}

class Notice extends StatelessWidget {
  final String text;
  final Color tone;
  const Notice(this.text, {super.key, this.tone = Tokens.warn});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: tone.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: tone.withValues(alpha: 0.25)),
        ),
        child: Row(children: [
          Icon(Icons.warning_rounded, color: tone, size: 18),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: Tokens.text(12.5))),
        ]),
      );
}

/// A screen's empty state: a title, a sentence, and the thing that fills it.
class Message extends StatelessWidget {
  final String title;
  final String detail;
  final Widget? action;
  final Color tone;
  const Message({super.key, required this.title, required this.detail, this.action, this.tone = Tokens.muted});

  @override
  Widget build(BuildContext context) => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(title, style: Tokens.text(17, weight: FontWeight.w600), textAlign: TextAlign.center),
              const SizedBox(height: 8),
              Text(detail, style: Tokens.text(13, color: tone), textAlign: TextAlign.center),
              if (action != null) ...[const SizedBox(height: 18), action!],
            ]),
          ),
        ),
      );
}

/// A KEY over a value, as the Cluster card lists its facts.
class Field extends StatelessWidget {
  final String label;
  final String value;
  const Field(this.label, this.value, {super.key});

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text(label, style: Tokens.text(10, weight: FontWeight.w600, color: Tokens.faint).copyWith(letterSpacing: 0.6)),
        const SizedBox(height: 3),
        Text(value, style: Tokens.mono(12), maxLines: 1, overflow: TextOverflow.ellipsis),
      ]);
}

/// The card every screen builds its content in.
class Panel extends StatelessWidget {
  final Widget child;
  final Color borderColor;
  final EdgeInsets padding;
  const Panel({super.key, required this.child, this.borderColor = Tokens.border, this.padding = const EdgeInsets.all(16)});

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: padding,
        decoration: BoxDecoration(
          color: Tokens.card,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: borderColor),
        ),
        child: child,
      );
}

/// A row inside a card, on the page background.
class Inset extends StatelessWidget {
  final Widget child;
  final Color? color;
  const Inset({super.key, required this.child, this.color});

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
        decoration: BoxDecoration(
          color: color ?? Tokens.bg,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: Tokens.border),
        ),
        child: child,
      );
}

/// Shows and hides the sidebar.
///
/// Needed because this app draws its own header rows and has no navigation
/// bar. With the sidebar collapsed this button is the leftmost thing on the
/// screen, which on iPadOS in a window is exactly where the system's own
/// controls sit, so only the collapsed state on iPadOS pads for them.
class SidebarToggle extends StatelessWidget {
  final bool collapsed;
  final VoidCallback onPressed;
  const SidebarToggle({super.key, required this.collapsed, required this.onPressed});

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.only(left: collapsed ? windowControlInset : 0),
        child: Tooltip(
          message: collapsed ? 'Show clusters' : 'Hide clusters',
          child: InkWell(
            onTap: onPressed,
            borderRadius: BorderRadius.circular(8),
            child: Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: Tokens.secondary,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Tokens.border),
              ),
              child: const Icon(Icons.view_sidebar_outlined, size: 17, color: Tokens.muted),
            ),
          ),
        ),
      );
}

/// A screen's header row: the sidebar toggle, a title, and whatever the
/// screen puts beside it.
class Toolbar extends StatelessWidget {
  final String title;
  final List<Widget> children;
  const Toolbar({super.key, required this.title, this.children = const []});

  @override
  Widget build(BuildContext context) {
    final split = SplitScope.of(context);
    return Container(
      height: 58,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Tokens.border))),
      child: Row(children: [
        SidebarToggle(collapsed: !split.sidebarShown, onPressed: split.toggle),
        const SizedBox(width: 12),
        Flexible(
          child: Text(title, style: Tokens.text(19, weight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        const SizedBox(width: 12),
        ...children,
      ]),
    );
  }
}

/// How the root lays out the sidebar, handed to the screens so their
/// toolbar can toggle it.
class SplitScope extends InheritedWidget {
  final bool sidebarShown;
  final VoidCallback toggle;
  const SplitScope({super.key, required this.sidebarShown, required this.toggle, required super.child});

  static SplitScope of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<SplitScope>()!;

  @override
  bool updateShouldNotify(SplitScope old) => old.sidebarShown != sidebarShown;
}

/// A filter chip: a menu's label, or a toggle.
class Choice extends StatelessWidget {
  final String text;
  final bool active;
  final bool menu;
  final Color? tint;
  final VoidCallback? onTap;
  const Choice(this.text, {super.key, this.active = false, this.menu = false, this.tint, this.onTap});

  static const activeFg = Color(0xFFA9C4FC);

  @override
  Widget build(BuildContext context) {
    final chip = Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 11),
      decoration: BoxDecoration(
        color: active ? Tokens.primary.withValues(alpha: 0.12) : Tokens.secondary,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: active ? Tokens.primary.withValues(alpha: 0.35) : Tokens.border),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (tint != null) ...[
          Container(width: 6, height: 6, decoration: BoxDecoration(color: tint, shape: BoxShape.circle)),
          const SizedBox(width: 6),
        ],
        Text(text, style: Tokens.text(12, weight: FontWeight.w600, color: active ? activeFg : Tokens.muted), maxLines: 1),
        if (menu) ...[
          const SizedBox(width: 6),
          const Icon(Icons.expand_more, size: 13, color: Tokens.faint),
        ],
      ]),
    );
    if (onTap == null) return chip;
    return InkWell(onTap: onTap, borderRadius: BorderRadius.circular(7), child: chip);
  }
}

/// A chip that opens a menu of choices.
class ChipMenu extends StatelessWidget {
  final String text;
  final bool active;
  final List<PopupMenuEntry<String>> items;
  final void Function(String) onSelected;
  const ChipMenu(this.text, {super.key, this.active = false, required this.items, required this.onSelected});

  @override
  Widget build(BuildContext context) => PopupMenuButton<String>(
        tooltip: '',
        color: Tokens.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: Tokens.border)),
        itemBuilder: (context) => items,
        onSelected: onSelected,
        child: Choice(text, active: active, menu: true),
      );
}

PopupMenuItem<String> menuItem(String value, String label, {IconData? icon}) => PopupMenuItem<String>(
      value: value,
      height: 34,
      child: Row(children: [
        if (icon != null) ...[Icon(icon, size: 14, color: Tokens.muted), const SizedBox(width: 8)],
        Text(label, style: Tokens.text(13)),
      ]),
    );

/// The toolbar's search box.
class SearchField extends StatelessWidget {
  final TextEditingController controller;
  final double width;
  final void Function(String) onChanged;
  const SearchField({super.key, required this.controller, this.width = 200, required this.onChanged});

  @override
  Widget build(BuildContext context) => Container(
        width: width,
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: Tokens.secondary,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Tokens.border),
        ),
        child: Row(children: [
          const Icon(Icons.search, size: 15, color: Tokens.muted),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: controller,
              onChanged: onChanged,
              autocorrect: false,
              enableSuggestions: false,
              style: Tokens.mono(12.5),
              decoration: InputDecoration.collapsed(hintText: 'Search', hintStyle: Tokens.mono(12.5, color: Tokens.faint)),
            ),
          ),
          ValueListenableBuilder(
            valueListenable: controller,
            builder: (context, value, _) => value.text.isEmpty
                ? const SizedBox.shrink()
                : InkWell(
                    onTap: () {
                      controller.clear();
                      onChanged('');
                    },
                    child: const Icon(Icons.cancel, size: 14, color: Tokens.faint),
                  ),
          ),
        ]),
      );
}

/// `3 days ago`, `in 2 hours`, as a row dates itself.
String relative(DateTime t, {DateTime? now}) {
  final d = (now ?? DateTime.now()).difference(t);
  final past = !d.isNegative;
  final abs = d.abs();
  String unit(int n, String u) => '$n $u${n == 1 ? '' : 's'}';
  final String span;
  if (abs.inSeconds < 60) {
    span = unit(abs.inSeconds, 'second');
  } else if (abs.inMinutes < 60) {
    span = unit(abs.inMinutes, 'minute');
  } else if (abs.inHours < 24) {
    span = unit(abs.inHours, 'hour');
  } else if (abs.inDays < 30) {
    span = unit(abs.inDays, 'day');
  } else if (abs.inDays < 365) {
    span = unit(abs.inDays ~/ 30, 'month');
  } else {
    span = unit(abs.inDays ~/ 365, 'year');
  }
  return past ? '$span ago' : 'in $span';
}

/// `09:24:18`, the clock a log line or a scan carries.
String clock(DateTime t) {
  final l = t.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(l.hour)}:${two(l.minute)}:${two(l.second)}';
}

/// A card with a title row: the shape every read-only screen builds from.
class TitledPanel extends StatelessWidget {
  final String title;
  final Widget? trailing;
  final List<Widget> children;
  final double spacing;
  const TitledPanel({super.key, required this.title, this.trailing, required this.children, this.spacing = 11});

  @override
  Widget build(BuildContext context) => Panel(
        padding: const EdgeInsets.all(15),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(title, style: Tokens.text(14, weight: FontWeight.w600))),
            if (trailing != null) ...[const SizedBox(width: 8), trailing!],
          ]),
          for (final child in children) ...[SizedBox(height: spacing), child],
        ]),
      );
}

/// A sentence with an information mark, at the bottom of a screen.
class Note extends StatelessWidget {
  final String text;
  const Note(this.text, {super.key});

  @override
  Widget build(BuildContext context) => Panel(
        padding: const EdgeInsets.all(14),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Icon(Icons.info_outline, size: 16, color: Tokens.muted),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: Tokens.text(12, color: Tokens.muted))),
        ]),
      );
}

/// `1 Jul 2027, 15:57`
String shortDate(DateTime t) {
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  final l = t.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${l.day} ${months[l.month - 1]} ${l.year}, ${two(l.hour)}:${two(l.minute)}';
}

/// `1.2K`, `3.4M`: a big count in a tile.
String compact(double v) {
  if (v.abs() < 1000) return v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
  const units = ['K', 'M', 'B', 'T'];
  var x = v;
  var i = -1;
  while (x.abs() >= 1000 && i < units.length - 1) {
    x /= 1000;
    i++;
  }
  return '${x.toStringAsFixed(x.abs() >= 100 ? 0 : 1)}${units[i]}';
}

/// `1.0 MiB`, as a disk size reads.
String bytesBinary(int bytes) {
  const units = ['bytes', 'KiB', 'MiB', 'GiB', 'TiB'];
  var x = bytes.toDouble();
  var i = 0;
  while (x >= 1024 && i < units.length - 1) {
    x /= 1024;
    i++;
  }
  return i == 0 ? '$bytes bytes' : '${x.toStringAsFixed(1)} ${units[i]}';
}
