/// The month grid of the wide calendar layout (APP.md §7): one cell per day
/// with a dot per item, today circled, tap to jump the agenda.
library;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:yams_models/yams_models.dart';

import '../providers/calendar_providers.dart';

class CalendarMonthGrid extends StatelessWidget {
  const CalendarMonthGrid({
    super.key,
    required this.month,
    required this.today,
    required this.marks,
    required this.firstDay,
    required this.lastDay,
    required this.onMonthChanged,
    required this.onDaySelected,
    this.selected,
  });

  /// Any day of the shown month (calendar date).
  final DateTime month;
  final DateTime today;
  final DateTime? selected;
  final Map<DateTime, CalendarDayMarks> marks;

  /// Days outside [firstDay]..[lastDay] cannot be selected.
  final DateTime firstDay;
  final DateTime lastDay;
  final ValueChanged<DateTime> onMonthChanged;
  final ValueChanged<DateTime> onDaySelected;

  static const _maxDots = 3;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final first = DateTime.utc(month.year, month.month);
    final daysInMonth = DateTime.utc(month.year, month.month + 1, 0).day;
    // Weeks start on Monday.
    final leading = first.weekday - DateTime.monday;
    final cells = ((leading + daysInMonth + 6) ~/ 7) * 7;
    final canGoBack = DateTime.utc(month.year, month.month).isAfter(DateTime.utc(firstDay.year, firstDay.month));
    final canGoForward = DateTime.utc(month.year, month.month).isBefore(DateTime.utc(lastDay.year, lastDay.month));
    final weekdays = [
      for (var i = 0; i < 7; i++) DateFormat('EEEEE').format(DateTime(2024, 1, 1 + i)), // 2024-01-01 is a Monday.
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              IconButton(
                tooltip: 'Previous month',
                icon: const Icon(Icons.chevron_left),
                onPressed: canGoBack ? () => onMonthChanged(DateTime.utc(month.year, month.month - 1)) : null,
              ),
              Expanded(
                child: Text(
                  DateFormat.yMMMM().format(DateTime(month.year, month.month)),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleMedium,
                ),
              ),
              IconButton(
                tooltip: 'Next month',
                icon: const Icon(Icons.chevron_right),
                onPressed: canGoForward ? () => onMonthChanged(DateTime.utc(month.year, month.month + 1)) : null,
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              for (final w in weekdays)
                Expanded(
                  child: Center(
                    child: Text(
                      w,
                      style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          GridView.count(
            crossAxisCount: 7,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            childAspectRatio: 0.9,
            children: [
              for (var i = 0; i < cells; i++)
                if (i < leading || i >= leading + daysInMonth)
                  const SizedBox.shrink()
                else
                  _dayCell(context, DateTime.utc(month.year, month.month, i - leading + 1)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _dayCell(BuildContext context, DateTime day) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final enabled = !day.isBefore(firstDay) && !day.isAfter(lastDay);
    final isToday = day == today;
    final isSelected = day == selected;
    final m = marks[day];
    final dots = <Color>[
      for (var i = 0; i < (m?.episodes ?? 0); i++) scheme.primary,
      for (var i = 0; i < (m?.movies ?? 0); i++) scheme.tertiary,
    ].take(_maxDots).toList();
    final count = m?.total ?? 0;
    final label =
        '${DateFormat.MMMMd().format(DateTime(day.year, day.month, day.day))}'
        '${count == 0 ? '' : ', $count ${count == 1 ? 'item' : 'items'}'}';

    return Semantics(
      button: enabled,
      selected: isSelected,
      label: label,
      excludeSemantics: true,
      child: InkWell(
        key: ValueKey('calendar-day-${CalendarDates.format(day)}'),
        customBorder: const CircleBorder(),
        onTap: enabled ? () => onDaySelected(day) : null,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 32,
              height: 32,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isToday ? scheme.primary : null,
                border: isSelected && !isToday ? Border.all(color: scheme.primary, width: 2) : null,
              ),
              child: Text(
                '${day.day}',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: isToday
                      ? scheme.onPrimary
                      : enabled
                      ? scheme.onSurface
                      : scheme.onSurface.withValues(alpha: 0.38),
                ),
              ),
            ),
            const SizedBox(height: 2),
            SizedBox(
              height: 6,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (final c in dots)
                    Container(
                      width: 5,
                      height: 5,
                      margin: const EdgeInsets.symmetric(horizontal: 1),
                      decoration: BoxDecoration(color: c, shape: BoxShape.circle),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
