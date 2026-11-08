/// Append-only audit log `$DATA/audit.jsonl` (ARCHITECTURE §5.13).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:yams_models/yams_models.dart';

import '../clock.dart';
import '../http/api_exception.dart';
import '../http/api_request.dart';
import '../ids.dart';
import '../posix.dart';
import '../upstream/upstream_exception.dart';
import 'sanitize.dart';

final _log = Logger('core.audit');

/// Who performed an audited action.
final class AuditActor {
  const AuditActor({this.userId, this.username, this.sessionId, this.ip});

  factory AuditActor.of(ApiRequest req) {
    final p = req.principal;
    return AuditActor(
      userId: p?.user.id,
      username: p?.user.username,
      sessionId: p?.session.id,
      ip: req.clientIp,
    );
  }

  final String? userId;
  final String? username;
  final String? sessionId;
  final String? ip;
}

/// The audit log. Entries are appended as JSON lines; the file rotates at
/// 10 MB keeping 5 old files (`audit.jsonl.1` .. `audit.jsonl.5`).
final class AuditLog {
  AuditLog({
    required String dataDir,
    required this._clock,
    this.maxBytes = 10 * 1024 * 1024,
    this.keepFiles = 5,
    this._usernameOf,
  }) : _path = p.join(dataDir, 'audit.jsonl');

  final String _path;
  final Clock _clock;
  final int maxBytes;
  final int keepFiles;
  String? Function(String userId)? _usernameOf;
  Future<void> _tail = Future.value();

  /// Resolves user names for entries recorded with a user id only (jobs).
  set usernameOf(String? Function(String userId) f) => _usernameOf = f;

  String get path => _path;

  /// Runs [fn] and records its outcome as [action] on [target].
  Future<T> run<T>(
    ApiRequest req,
    String action,
    String? target,
    Map<String, Object?>? params,
    Future<T> Function() fn,
  ) async {
    final sw = Stopwatch()..start();
    try {
      final result = await fn();
      final errorCode = result is Response && result.statusCode >= 400
          ? (result.context[ContextKeys.errorCode] as String? ??
                'http_${result.statusCode}')
          : null;
      await record(
        actor: AuditActor.of(req),
        action: action,
        target: target,
        params: params,
        outcome: errorCode == null ? AuditOutcome.ok : AuditOutcome.error,
        errorCode: errorCode,
        duration: sw.elapsed,
      );
      return result;
    } catch (e) {
      await record(
        actor: AuditActor.of(req),
        action: action,
        target: target,
        params: params,
        outcome: AuditOutcome.error,
        errorCode: errorCodeOf(e),
        duration: sw.elapsed,
      );
      rethrow;
    }
  }

  /// Audits an `audit: true` route: target = path parameters, params = query
  /// plus JSON body.
  Future<Response> runRoute(
    ApiRequest req,
    String action,
    Future<Response> Function() fn,
  ) async {
    final target = req.pathParams.isEmpty
        ? null
        : req.pathParams.values.join('/');
    Map<String, Object?>? params;
    Future<Map<String, Object?>?> collect() async {
      JsonMap? body;
      try {
        body = await req.jsonBodyOrNull();
      } catch (_) {
        // The handler consumed the body itself; audit without it.
        body = null;
      }
      final query = Map<String, Object?>.of(req.query);
      if ((body == null || body.isEmpty) && query.isEmpty) return null;
      return {...query, ...?body};
    }

    final sw = Stopwatch()..start();
    try {
      final response = await fn();
      params = await collect();
      final failed = response.statusCode >= 400;
      await record(
        actor: AuditActor.of(req),
        action: req.auditAction ?? action,
        target: target,
        params: params,
        outcome: failed ? AuditOutcome.error : AuditOutcome.ok,
        errorCode: failed
            ? (response.context[ContextKeys.errorCode] as String? ??
                  'http_${response.statusCode}')
            : null,
        duration: sw.elapsed,
      );
      return response;
    } catch (e) {
      params = await collect();
      // A 428 means nothing was changed: not worth an entry.
      if (e is! ApiException || e.status != 428) {
        await record(
          actor: AuditActor.of(req),
          action: req.auditAction ?? action,
          target: target,
          params: params,
          outcome: AuditOutcome.error,
          errorCode: errorCodeOf(e),
          duration: sw.elapsed,
        );
      }
      rethrow;
    }
  }

  /// Appends one entry. Never throws (a failing audit write is logged).
  Future<void> record({
    AuditActor actor = const AuditActor(),
    required String action,
    String? target,
    Map<String, Object?>? params,
    AuditOutcome outcome = AuditOutcome.ok,
    String? errorCode,
    Duration duration = Duration.zero,
  }) {
    final username =
        actor.username ??
        (actor.userId == null ? null : _usernameOf?.call(actor.userId!));
    final entry = AuditEntry(
      id: 'a_${randomHex(16)}',
      at: _clock.now(),
      userId: actor.userId,
      username: username,
      sessionId: actor.sessionId,
      ip: actor.ip,
      action: action,
      target: target,
      params: sanitizeAuditParams(params),
      outcome: outcome,
      errorCode: errorCode,
      durationMs: duration.inMilliseconds,
    );
    final line = '${jsonEncode(entry.toJson())}\n';
    return _tail = _tail.then((_) => _append(line)).catchError((Object e) {
      _log.severe('could not write the audit log', e);
    });
  }

  Future<void> _append(String line) async {
    final file = File(_path);
    final exists = await file.exists();
    if (!exists) {
      await file.parent.create(recursive: true);
    } else if (await file.length() + line.length > maxBytes) {
      await _rotate();
    }
    final created = !await file.exists();
    await file.writeAsString(line, mode: FileMode.append, flush: true);
    if (created) chmod(_path, 384);
  }

  Future<void> _rotate() async {
    for (var i = keepFiles; i >= 1; i--) {
      final f = File('$_path.$i');
      if (!await f.exists()) continue;
      if (i == keepFiles) {
        await f.delete();
      } else {
        await f.rename('$_path.${i + 1}');
      }
    }
    await File(_path).rename('$_path.1');
  }

  /// Waits for pending writes.
  Future<void> flush() => _tail;

  /// Reads entries newest first, filtered and paged.
  Future<PagedList<AuditEntry>> query({
    int page = 1,
    int pageSize = 50,
    String? userId,
    String? actionPrefix,
    AuditOutcome? outcome,
  }) async {
    await flush();
    final matches = <AuditEntry>[];
    final files = [
      File(_path),
      for (var i = 1; i <= keepFiles; i++) File('$_path.$i'),
    ];
    for (final f in files) {
      if (!await f.exists()) continue;
      final lines = await f.readAsLines();
      for (final line in lines.reversed) {
        if (line.trim().isEmpty) continue;
        final AuditEntry e;
        try {
          final m = readMap(jsonDecode(line));
          if (m == null) continue;
          e = AuditEntry.fromJson(m);
        } on FormatException {
          continue;
        }
        if (userId != null && e.userId != userId) continue;
        if (actionPrefix != null && !e.action.startsWith(actionPrefix)) {
          continue;
        }
        if (outcome != null && e.outcome != outcome) continue;
        matches.add(e);
      }
    }
    final start = (page - 1) * pageSize;
    final items = start >= matches.length
        ? <AuditEntry>[]
        : matches.sublist(start, (start + pageSize).clamp(0, matches.length));
    return PagedList.of(
      items: items,
      page: page,
      pageSize: pageSize,
      total: matches.length,
    );
  }
}

/// The API error code an exception maps to (for audit entries and jobs).
String errorCodeOf(Object e) => switch (e) {
  ApiException() => e.code,
  UpstreamException() => e.toApiException().code,
  FormatException() || TypeError() => ApiErrorCode.upstreamBadResponse,
  _ => ApiErrorCode.internal,
};
