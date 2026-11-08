/// Screen shown by route stubs until the owning feature slice lands.
library;

import 'package:flutter/material.dart';

import '../widgets/empty_view.dart';

class PlaceholderScreen extends StatelessWidget {
  const PlaceholderScreen({super.key, required this.title, this.message});

  final String title;
  final String? message;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: EmptyView(
        icon: Icons.construction_outlined,
        title: title,
        message: message ?? 'This screen is not available yet.',
      ),
    );
  }
}
