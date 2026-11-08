/// A strict, allocation-free structural check of `.torrent` files.
library;

/// Whether [bytes] is one complete bencoded dictionary (optionally followed by
/// ASCII whitespace) whose top level has an `info` key, i.e. something
/// qBittorrent can add as a `.torrent` file. HTML error pages, JSON and
/// truncated downloads are rejected.
bool isTorrentFile(List<int> bytes, {int maxDepth = 64}) {
  if (bytes.isEmpty || bytes[0] != _d) return false;
  final parser = _BencodeParser(bytes, maxDepth);
  try {
    final hasInfo = parser.topLevelDictHasInfo();
    var i = parser.pos;
    while (i < bytes.length && _isSpace(bytes[i])) {
      i++;
    }
    return hasInfo && i == bytes.length;
  } on FormatException {
    return false;
  }
}

const _d = 0x64; // d
const _l = 0x6c; // l
const _i = 0x69; // i
const _e = 0x65; // e
const _colon = 0x3a;
const _minus = 0x2d;
const _zero = 0x30;
const _nine = 0x39;

bool _isSpace(int b) => b == 0x20 || b == 0x0a || b == 0x0d || b == 0x09;

final class _BencodeParser {
  _BencodeParser(this.bytes, this.maxDepth);

  final List<int> bytes;
  final int maxDepth;
  int pos = 0;

  int _peek() {
    if (pos >= bytes.length) throw const FormatException('truncated');
    return bytes[pos];
  }

  bool topLevelDictHasInfo() {
    pos++; // 'd'
    var hasInfo = false;
    while (_peek() != _e) {
      // BEP 3 wants sorted, unique keys; tolerate unsorted keys from sloppy
      // encoders but not a second `info`.
      if (_string(capture: true) == 'info') {
        if (hasInfo) throw const FormatException('duplicate info');
        hasInfo = true;
      }
      _value(1);
    }
    pos++;
    return hasInfo;
  }

  void _value(int depth) {
    if (depth > maxDepth) throw const FormatException('too deep');
    final b = _peek();
    switch (b) {
      case _i:
        _integer();
      case _l:
        pos++;
        while (_peek() != _e) {
          _value(depth + 1);
        }
        pos++;
      case _d:
        pos++;
        while (_peek() != _e) {
          _string();
          _value(depth + 1);
        }
        pos++;
      case >= _zero && <= _nine:
        _string();
      default:
        throw const FormatException('unexpected byte');
    }
  }

  void _integer() {
    pos++; // 'i'
    if (_peek() == _minus) pos++;
    final start = pos;
    while (_peek() != _e) {
      final c = bytes[pos];
      if (c < _zero || c > _nine) throw const FormatException('bad integer');
      pos++;
    }
    if (pos == start) throw const FormatException('empty integer');
    pos++; // 'e'
  }

  String? _string({bool capture = false}) {
    final start = pos;
    var length = 0;
    while (_peek() != _colon) {
      final c = bytes[pos];
      if (c < _zero || c > _nine) throw const FormatException('bad length');
      length = length * 10 + (c - _zero);
      if (length > bytes.length) throw const FormatException('bad length');
      pos++;
    }
    if (pos == start) throw const FormatException('empty length');
    pos++; // ':'
    final end = pos + length;
    if (end > bytes.length) throw const FormatException('truncated string');
    final value = capture ? String.fromCharCodes(bytes, pos, end) : null;
    pos = end;
    return value;
  }
}
