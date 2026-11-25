import 'package:flutter/material.dart';

import 'theme.dart';

/// A section title above a [SettingsGroup].
class SettingsSection extends StatelessWidget {
  const SettingsSection(this.title, {super.key});
  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 28, 20, 8),
    child: Text(title, style: context.type.titleSmall?.copyWith(color: context.yt.inkSoft)),
  );
}

/// Small print under a [SettingsGroup].
class SettingsFootnote extends StatelessWidget {
  const SettingsFootnote(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
    child: Text(text, style: context.type.bodySmall),
  );
}

/// An inset group of rows on a white surface, separated by hairlines.
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final p = context.yt;
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) rows.add(const Divider(indent: 16));
      rows.add(children[i]);
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Material(
        color: p.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: p.hairline),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(children: rows),
      ),
    );
  }
}

/// The red dot that says a newer version is out. Only a dot: the app never
/// interrupts with a dialog about it.
class UpdateDot extends StatelessWidget {
  const UpdateDot({super.key});

  @override
  Widget build(BuildContext context) => Semantics(
    label: '有新版本',
    child: Container(
      key: const ValueKey('update-dot'),
      width: 8,
      height: 8,
      decoration: BoxDecoration(shape: BoxShape.circle, color: Theme.of(context).colorScheme.error),
    ),
  );
}
