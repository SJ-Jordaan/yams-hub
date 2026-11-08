import 'package:flutter/material.dart';

/// One row of a [KeyValueList]: a label and a text or widget value.
class KeyValue {
  const KeyValue(this.label, this.value) : child = null;

  const KeyValue.widget(this.label, Widget this.child) : value = null;

  final String label;
  final String? value;
  final Widget? child;
}

/// Label/value rows (detail screens). Rows whose value is null or empty are
/// skipped.
class KeyValueList extends StatelessWidget {
  const KeyValueList({super.key, required this.entries, this.labelWidth = 140, this.dense = false});

  final List<KeyValue> entries;
  final double labelWidth;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rows = entries.where((e) => e.child != null || (e.value != null && e.value!.isNotEmpty));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final e in rows)
          Padding(
            padding: EdgeInsets.symmetric(vertical: dense ? 2 : 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: labelWidth,
                  child: Text(
                    e.label,
                    style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
                Expanded(child: e.child ?? SelectableText(e.value!, style: theme.textTheme.bodyMedium)),
              ],
            ),
          ),
      ],
    );
  }
}
