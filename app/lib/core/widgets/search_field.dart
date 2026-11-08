import 'dart:async';

import 'package:flutter/material.dart';

/// A search box that reports changes after [debounce] (and immediately on
/// submit or clear).
class SearchField extends StatefulWidget {
  const SearchField({
    super.key,
    required this.onChanged,
    this.hint = 'Search',
    this.initialValue,
    this.debounce = const Duration(milliseconds: 350),
    this.autofocus = false,
  });

  final ValueChanged<String> onChanged;
  final String hint;
  final String? initialValue;
  final Duration debounce;
  final bool autofocus;

  @override
  State<SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<SearchField> {
  late final TextEditingController _controller = TextEditingController(text: widget.initialValue);
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _emit(String value, {bool now = false}) {
    _timer?.cancel();
    if (now) {
      widget.onChanged(value.trim());
    } else {
      _timer = Timer(widget.debounce, () => widget.onChanged(value.trim()));
    }
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      autofocus: widget.autofocus,
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        hintText: widget.hint,
        prefixIcon: const Icon(Icons.search),
        isDense: true,
        suffixIcon: ListenableBuilder(
          listenable: _controller,
          builder: (context, _) => _controller.text.isEmpty
              ? const SizedBox.shrink()
              : IconButton(
                  tooltip: 'Clear',
                  icon: const Icon(Icons.clear),
                  onPressed: () {
                    _controller.clear();
                    _emit('', now: true);
                  },
                ),
        ),
      ),
      onChanged: _emit,
      onSubmitted: (v) => _emit(v, now: true),
    );
  }
}
