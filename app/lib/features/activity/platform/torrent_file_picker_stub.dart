/// No file picker outside the browser.
library;

import 'torrent_file_picker.dart';

/// Whether this platform can pick `.torrent` files.
bool get canPickTorrentFiles => false;

/// Picks `.torrent` files (never on this platform).
Future<List<PickedTorrentFile>> pickTorrentFiles() async => const [];
