/// Docker log body decoding (integrations/system.md §1.5).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:yams_models/yams_models.dart';

/// Longest line text kept (longer lines are cut, with an ellipsis).
const dockerLogMaxLineChars = 4096;

/// One decoded log line (not redacted yet).
final class DockerLogLine {
  const DockerLogLine({required this.stream, required this.text, this.at});

  final DateTime? at;
  final ContainerLogStream stream;
  final String text;
}

final _timestamp = RegExp(
  r'^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(?:\.(\d{1,9}))?(Z|[+-]\d{2}:\d{2}) ?',
);

/// Splits Docker's RFC 3339 nano timestamp prefix off [line].
(DateTime?, String) splitDockerTimestamp(String line) {
  final m = _timestamp.firstMatch(line);
  if (m == null) return (null, line);
  final frac = m[2];
  // Dart keeps microseconds: cut nanoseconds to 6 digits.
  final micros = frac == null
      ? ''
      : '.${(frac.length > 6 ? frac.substring(0, 6) : frac)}';
  final at = DateTime.tryParse('${m[1]}$micros${m[3]}')?.toUtc();
  if (at == null) return (null, line);
  return (at, line.substring(m.end));
}

/// Whether [bytes] looks like Docker's multiplexed stream (a frame header
/// `[1|2, 0, 0, 0, size:u32be]`).
bool looksMultiplexed(List<int> bytes) =>
    bytes.length >= 8 &&
    (bytes[0] == 0 || bytes[0] == 1 || bytes[0] == 2) &&
    bytes[1] == 0 &&
    bytes[2] == 0 &&
    bytes[3] == 0;

/// Decodes a `GET /containers/{id}/logs` body. Non-TTY containers send
/// multiplexed frames `[stream][0,0,0][size u32be][payload]`; a frame is not
/// necessarily one line, so payloads are split on `\n` with partial lines
/// kept per stream across frames. [tty] bodies are raw text (stdout).
/// With [timestamps] every line starts with an RFC 3339 nano timestamp.
List<DockerLogLine> decodeDockerLogs(
  List<int> body, {
  required bool tty,
  bool timestamps = true,
}) {
  final out = <DockerLogLine>[];
  void emit(ContainerLogStream stream, List<int> lineBytes) {
    var text = utf8.decode(lineBytes, allowMalformed: true);
    if (text.endsWith('\r')) text = text.substring(0, text.length - 1);
    DateTime? at;
    if (timestamps) (at, text) = splitDockerTimestamp(text);
    if (text.length > dockerLogMaxLineChars) {
      text = '${text.substring(0, dockerLogMaxLineChars)}…';
    }
    out.add(DockerLogLine(stream: stream, text: text, at: at));
  }

  if (tty || !looksMultiplexed(body)) {
    _splitLines(
      body,
      (line) => emit(ContainerLogStream.stdout, line),
      flush: true,
    );
    return out;
  }

  final pending = <ContainerLogStream, BytesBuilder>{};
  final data = body is Uint8List ? body : Uint8List.fromList(body);
  var offset = 0;
  while (offset + 8 <= data.length) {
    final streamByte = data[offset];
    final size = ByteData.sublistView(
      data,
      offset + 4,
      offset + 8,
    ).getUint32(0);
    final start = offset + 8;
    final end = (start + size).clamp(start, data.length);
    final stream = streamByte == 2
        ? ContainerLogStream.stderr
        : ContainerLogStream.stdout;
    final buffer = pending.putIfAbsent(stream, BytesBuilder.new);
    var lineStart = start;
    for (var i = start; i < end; i++) {
      if (data[i] == 0x0A) {
        buffer.add(Uint8List.sublistView(data, lineStart, i));
        emit(stream, buffer.takeBytes());
        lineStart = i + 1;
      }
    }
    if (lineStart < end) {
      buffer.add(Uint8List.sublistView(data, lineStart, end));
    }
    offset = end;
  }
  for (final e in pending.entries) {
    if (e.value.isNotEmpty) emit(e.key, e.value.takeBytes());
  }
  return out;
}

void _splitLines(
  List<int> bytes,
  void Function(List<int> line) onLine, {
  required bool flush,
}) {
  var start = 0;
  for (var i = 0; i < bytes.length; i++) {
    if (bytes[i] == 0x0A) {
      onLine(bytes.sublist(start, i));
      start = i + 1;
    }
  }
  if (flush && start < bytes.length) onLine(bytes.sublist(start));
}
