/// `statvfs(3)` through `dart:ffi` (API.md §13.1: usage of `/volume1` via
/// the `/data` bind mount).
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Block counts of a file system, in bytes.
final class FsUsage {
  const FsUsage({
    required this.totalBytes,
    required this.freeBytes,
    required this.availableBytes,
  });

  /// `f_blocks × f_frsize`.
  final int totalBytes;

  /// `f_bfree × f_frsize` (including blocks reserved for root).
  final int freeBytes;

  /// `f_bavail × f_frsize` (what unprivileged users can still write).
  final int availableBytes;

  /// `total − free`, like `df`.
  int get usedBytes => (totalBytes - freeBytes).clamp(0, totalBytes);

  /// `used / (used + available) × 100`, like `df`'s Capacity column.
  double get usedPercent {
    final denominator = usedBytes + availableBytes;
    return denominator <= 0 ? 0 : usedBytes / denominator * 100;
  }
}

/// Reads file-system usage of a path; null when unavailable.
typedef FsUsageReader = FsUsage? Function(String path);

typedef _StatvfsNative = Int32 Function(Pointer<Utf8> path, Pointer<Uint8> buf);
typedef _StatvfsDart = int Function(Pointer<Utf8> path, Pointer<Uint8> buf);

_StatvfsDart? _statvfsFn;
bool _lookedUp = false;

_StatvfsDart? _lookup() {
  if (_lookedUp) return _statvfsFn;
  _lookedUp = true;
  // The struct layout below is the 64-bit Linux one (glibc and musl agree on
  // the first five fields: unsigned long f_bsize, f_frsize; fsblkcnt_t
  // f_blocks, f_bfree, f_bavail, all 8 bytes).
  if (!Platform.isLinux || sizeOf<IntPtr>() != 8) return null;
  try {
    return _statvfsFn = DynamicLibrary.process()
        .lookupFunction<_StatvfsNative, _StatvfsDart>('statvfs');
  } on ArgumentError {
    return null;
  }
}

/// `statvfs(path)` on 64-bit Linux; null elsewhere or when the call fails.
FsUsage? statvfsUsage(String path) {
  final fn = _lookup();
  if (fn == null) return null;
  // struct statvfs is 112 bytes on x86_64/aarch64; over-allocate.
  final buf = calloc<Uint8>(256);
  final cPath = path.toNativeUtf8();
  try {
    if (fn(cPath, buf) != 0) return null;
    final words = buf.cast<Uint64>();
    final bsize = words[0];
    final frsize = words[1] == 0 ? bsize : words[1];
    return FsUsage(
      totalBytes: words[2] * frsize,
      freeBytes: words[3] * frsize,
      availableBytes: words[4] * frsize,
    );
  } finally {
    calloc.free(buf);
    malloc.free(cPath);
  }
}
