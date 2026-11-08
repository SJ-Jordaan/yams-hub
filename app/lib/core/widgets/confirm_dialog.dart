import 'package:flutter/material.dart';

import '../theme/theme.dart';

/// Confirmation dialog for destructive actions (APP.md §2.4). After the user
/// confirms, the caller sends `confirm=true`.
///
/// ```dart
/// if (await ConfirmDialog.show(context, title: 'Stop gluetun?', message: '...', destructive: true)) { ... }
/// ```
///
/// Options (checkboxes, radios) go in [content]; keep their state in the
/// caller (e.g. a `StatefulBuilder`) and read it after `show` returns true.
class ConfirmDialog extends StatelessWidget {
  const ConfirmDialog({
    super.key,
    required this.title,
    this.message,
    this.content,
    this.confirmLabel = 'Confirm',
    this.cancelLabel = 'Cancel',
    this.destructive = false,
  });

  final String title;
  final String? message;
  final Widget? content;
  final String confirmLabel;
  final String cancelLabel;
  final bool destructive;

  /// Shows the dialog; true only when the user confirmed.
  static Future<bool> show(
    BuildContext context, {
    required String title,
    String? message,
    Widget? content,
    String confirmLabel = 'Confirm',
    String cancelLabel = 'Cancel',
    bool destructive = false,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (_) => ConfirmDialog(
        title: title,
        message: message,
        content: content,
        confirmLabel: confirmLabel,
        cancelLabel: cancelLabel,
        destructive: destructive,
      ),
    );
    return result ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final danger = StatusColors.of(context).error;
    return AlertDialog(
      title: Text(title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (message != null) Text(message!),
            if (message != null && content != null) const SizedBox(height: 12),
            ?content,
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(cancelLabel)),
        FilledButton(
          style: destructive ? FilledButton.styleFrom(backgroundColor: danger, foregroundColor: Colors.white) : null,
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(confirmLabel),
        ),
      ],
    );
  }
}

/// Red confirmation that requires typing [expected] (the title, or `SEARCH`)
/// before the confirm button enables (APP.md §2.4).
class TypedConfirmDialog extends StatefulWidget {
  const TypedConfirmDialog({
    super.key,
    required this.title,
    required this.expected,
    this.message,
    this.confirmLabel = 'Delete',
  });

  final String title;
  final String expected;
  final String? message;
  final String confirmLabel;

  /// Shows the dialog; true only when the user typed [expected] and confirmed.
  static Future<bool> show(
    BuildContext context, {
    required String expected,
    String title = 'Are you sure?',
    String? message,
    String confirmLabel = 'Delete',
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (_) => TypedConfirmDialog(
        title: title,
        expected: expected,
        message: message,
        confirmLabel: confirmLabel,
      ),
    );
    return result ?? false;
  }

  @override
  State<TypedConfirmDialog> createState() => _TypedConfirmDialogState();
}

class _TypedConfirmDialogState extends State<TypedConfirmDialog> {
  final _controller = TextEditingController();

  bool get _matches => _controller.text.trim() == widget.expected.trim();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final danger = StatusColors.of(context).error;
    return AlertDialog(
      icon: Icon(Icons.warning_amber_rounded, color: danger),
      title: Text(widget.title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.message != null) ...[Text(widget.message!), const SizedBox(height: 12)],
            Text.rich(
              TextSpan(
                children: [
                  const TextSpan(text: 'Type '),
                  TextSpan(text: widget.expected, style: const TextStyle(fontWeight: FontWeight.bold)),
                  const TextSpan(text: ' to confirm.'),
                ],
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _controller,
              autofocus: true,
              autocorrect: false,
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) {
                if (_matches) Navigator.of(context).pop(true);
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: danger, foregroundColor: Colors.white),
          onPressed: _matches ? () => Navigator.of(context).pop(true) : null,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}
