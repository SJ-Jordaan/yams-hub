/// `.torrent` file picking: web only (a hidden `<input type="file">` through
/// `package:web`); the phone apps have no file-picker package (APP.md §6.4).
library;

export 'torrent_file_picker_stub.dart' if (dart.library.js_interop) 'torrent_file_picker_web.dart';

/// A picked `.torrent` file.
class PickedTorrentFile {
  const PickedTorrentFile(this.name, this.bytes);

  final String name;
  final List<int> bytes;
}
