/// `multipart/form-data` bodies (qBittorrent `torrents/add`).
library;

import 'dart:convert';
import 'dart:typed_data';

import '../ids.dart';

/// One part of a multipart body.
sealed class MultipartPart {
  const MultipartPart();

  /// A text field.
  const factory MultipartPart.field(String name, String value) = MultipartField;

  /// A file.
  const factory MultipartPart.file(
    String name,
    String filename,
    List<int> bytes,
    String contentType,
  ) = MultipartFile;

  String get name;
}

final class MultipartField extends MultipartPart {
  const MultipartField(this.name, this.value);

  @override
  final String name;
  final String value;
}

final class MultipartFile extends MultipartPart {
  const MultipartFile(this.name, this.filename, this.bytes, this.contentType);

  @override
  final String name;
  final String filename;
  final List<int> bytes;
  final String contentType;
}

/// An encoded multipart body and its content type (with boundary).
final class MultipartBody {
  const MultipartBody(this.contentType, this.bytes);

  final String contentType;
  final Uint8List bytes;
}

String _quote(String s) => s
    .replaceAll('\\', '\\\\')
    .replaceAll('"', '%22')
    .replaceAll('\r', '%0D')
    .replaceAll('\n', '%0A');

/// Encodes [parts] with a random boundary.
MultipartBody encodeMultipart(List<MultipartPart> parts) {
  final boundary = 'yams-hub-${randomHex(24)}';
  final out = BytesBuilder(copy: false);
  void line(String s) => out.add(utf8.encode('$s\r\n'));
  for (final part in parts) {
    line('--$boundary');
    switch (part) {
      case MultipartField(:final name, :final value):
        line('Content-Disposition: form-data; name="${_quote(name)}"');
        line('');
        out.add(utf8.encode(value));
        line('');
      case MultipartFile(
        :final name,
        :final filename,
        :final bytes,
        :final contentType,
      ):
        line(
          'Content-Disposition: form-data; name="${_quote(name)}"; '
          'filename="${_quote(filename)}"',
        );
        line('Content-Type: $contentType');
        line('');
        out.add(bytes);
        line('');
    }
  }
  line('--$boundary--');
  return MultipartBody(
    'multipart/form-data; boundary=$boundary',
    out.takeBytes(),
  );
}
