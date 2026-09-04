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

class Banner extends StatelessWidget {
  final String text;
  final Color tone;
  const Banner(this.text, {super.key, this.tone = Tokens.warn});

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
  const Message({super.key, required this.title, required this.detail, this.action});

  @override
  Widget build(BuildContext context) => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(title, style: Tokens.text(17, weight: FontWeight.w600), textAlign: TextAlign.center),
              const SizedBox(height: 8),
              Text(detail, style: Tokens.text(13, color: Tokens.muted), textAlign: TextAlign.center),
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
