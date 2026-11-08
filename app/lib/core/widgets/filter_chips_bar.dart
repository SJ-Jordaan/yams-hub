import 'package:flutter/material.dart';

/// A horizontally scrolling row of filter chips.
///
/// Single choice by default ([onSelected] receives the tapped value; tapping
/// the selected chip again passes null when [allowDeselect]). With [multi],
/// [selected] may hold several values and taps toggle them.
class FilterChipsBar<T> extends StatelessWidget {
  const FilterChipsBar({
    super.key,
    required this.options,
    required this.selected,
    required this.onSelected,
    required this.labelOf,
    this.multi = false,
    this.allowDeselect = false,
    this.padding = const EdgeInsets.symmetric(horizontal: 16),
  });

  final List<T> options;
  final Set<T> selected;

  /// Single choice: the new value (or null). Multi: the toggled value.
  final ValueChanged<T?> onSelected;
  final String Function(T value) labelOf;
  final bool multi;
  final bool allowDeselect;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: padding,
      child: Row(
        children: [
          for (final option in options)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilterChip(
                label: Text(labelOf(option)),
                selected: selected.contains(option),
                showCheckmark: multi,
                onSelected: (_) {
                  if (multi) {
                    onSelected(option);
                  } else if (selected.contains(option)) {
                    if (allowDeselect) onSelected(null);
                  } else {
                    onSelected(option);
                  }
                },
              ),
            ),
        ],
      ),
    );
  }
}
