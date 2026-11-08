/// Browser `.torrent` picker: a hidden `<input type="file" accept=".torrent"
/// multiple>`; files are read as bytes.
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'torrent_file_picker.dart';

/// Whether this platform can pick `.torrent` files.
bool get canPickTorrentFiles => true;

/// Opens the browser's file dialog; an empty list when cancelled.
Future<List<PickedTorrentFile>> pickTorrentFiles() async {
  final input = web.HTMLInputElement()
    ..type = 'file'
    ..accept = '.torrent,application/x-bittorrent'
    ..multiple = true;
  final changed = Completer<void>();
  input.onchange = ((web.Event _) {
    if (!changed.isCompleted) changed.complete();
  }).toJS;
  input.oncancel = ((web.Event _) {
    if (!changed.isCompleted) changed.complete();
  }).toJS;
  input.click();
  await changed.future;
  final files = input.files;
  if (files == null) return const [];
  final out = <PickedTorrentFile>[];
  for (var i = 0; i < files.length; i++) {
    final file = files.item(i);
    if (file == null) continue;
    final buffer = await file.arrayBuffer().toDart;
    out.add(PickedTorrentFile(file.name, Uint8List.view(buffer.toDart)));
  }
  return out;
}
