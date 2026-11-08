/// Add torrent as a page, `/activity/add?url=` (admin, APP.md §6.4): the
/// target of `magnet:` links handed to the app.
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:yams_hub/core/routing/paths.dart';

import '../widgets/add_torrent_form.dart';

class AddTorrentScreen extends StatelessWidget {
  const AddTorrentScreen({super.key, this.url});

  /// Pre-fills the link field (a magnet link from the OS).
  final String? url;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Add torrent')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.only(top: 16),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: AddTorrentForm(
                initialUrl: url,
                onAdded: () => context.go(AppPaths.activity(tab: 'torrents')),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
