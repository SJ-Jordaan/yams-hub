/// Reading response bodies with a size cap and a deadline.
library;

import 'dart:async';
import 'dart:typed_data';

/// The body exceeded the allowed size; the stream was cancelled.
final class BodyTooLargeException implements Exception {
  const BodyTooLargeException(this.maxBytes);

  final int maxBytes;

  @override
  String toString() => 'BodyTooLargeException(> $maxBytes bytes)';
}

/// Reads [stream] into memory. Cancels the subscription and throws
/// [BodyTooLargeException] once more than [maxBytes] arrived, or a
/// [TimeoutException] when [timeout] elapses first.
Future<Uint8List> readCapped(
  Stream<List<int>> stream, {
  int? maxBytes,
  Duration? timeout,
}) {
  final completer = Completer<Uint8List>();
  final builder = BytesBuilder(copy: false);
  Timer? timer;
  late final StreamSubscription<List<int>> sub;

  void fail(Object error, [StackTrace? st]) {
    if (completer.isCompleted) return;
    timer?.cancel();
    unawaited(sub.cancel().catchError((Object _) {}));
    completer.completeError(error, st);
  }

  sub = stream.listen(
    (chunk) {
      builder.add(chunk);
      if (maxBytes != null && builder.length > maxBytes) {
        fail(BodyTooLargeException(maxBytes));
      }
    },
    onError: fail,
    onDone: () {
      timer?.cancel();
      if (!completer.isCompleted) completer.complete(builder.takeBytes());
    },
    cancelOnError: true,
  );
  if (timeout != null) {
    timer = Timer(timeout, () => fail(TimeoutException('body read', timeout)));
  }
  return completer.future;
}
