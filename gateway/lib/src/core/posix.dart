/// Minimal libc bindings: `umask` and `chmod` (ARCHITECTURE §5.1).
///
/// dart:io cannot set a process umask or a file mode, and the runtime image has
/// no shell. Both calls are no-ops on platforms without libc symbols.
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

typedef _UmaskNative = Uint32 Function(Uint32 mask);
typedef _UmaskDart = int Function(int mask);
typedef _ChmodNative = Int32 Function(Pointer<Utf8> path, Uint32 mode);
typedef _ChmodDart = int Function(Pointer<Utf8> path, int mode);

final bool _posix = Platform.isLinux || Platform.isMacOS;

_UmaskDart? _umaskFn;
_ChmodDart? _chmodFn;

_UmaskDart? _lookupUmask() {
  if (!_posix) return null;
  try {
    return _umaskFn ??= DynamicLibrary.process()
        .lookupFunction<_UmaskNative, _UmaskDart>('umask');
  } on ArgumentError {
    return null;
  }
}

_ChmodDart? _lookupChmod() {
  if (!_posix) return null;
  try {
    return _chmodFn ??= DynamicLibrary.process()
        .lookupFunction<_ChmodNative, _ChmodDart>('chmod');
  } on ArgumentError {
    return null;
  }
}

/// Sets the process umask and returns the previous one, or null when the
/// platform has no `umask`.
int? setUmask(int mask) => _lookupUmask()?.call(mask);

/// Sets [path]'s permission bits. Returns false when the call failed or is not
/// available.
bool chmod(String path, int mode) {
  final fn = _lookupChmod();
  if (fn == null) return false;
  final p = path.toNativeUtf8();
  try {
    return fn(p, mode) == 0;
  } finally {
    malloc.free(p);
  }
}
