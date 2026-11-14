/// Posts the gateway's few out-of-app alerts to a Discord webhook
/// (ARCHITECTURE §5.7.1).
///
/// The webhook URL is a secret (anyone holding it can post to the channel):
/// it is never logged, printed or put in an exception message.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:logging/logging.dart';

import '../../version.dart';

final _id = RegExp(r'^[0-9]{1,30}$');
final _token = RegExp(r'^[A-Za-z0-9_.-]{1,200}$');
final _apiVersion = RegExp(r'^v[0-9]{1,2}$');

/// Validates a Discord webhook URL
/// (`https://discord.com/api[/v10]/webhooks/<id>/<token>`, or the older
/// `discordapp.com` host) and returns it without a trailing slash; null when
/// it is anything else. Queries, fragments, credentials and other ports are
/// refused, so the gateway can only ever post to Discord with it.
Uri? parseDiscordWebhookUrl(String text) {
  final u = Uri.tryParse(text.trim());
  if (u == null || u.scheme != 'https') return null;
  final host = u.host.toLowerCase();
  if (host != 'discord.com' && host != 'discordapp.com') return null;
  if (u.hasPort && u.port != 443) return null;
  if (u.userInfo.isNotEmpty || u.hasQuery || u.hasFragment) return null;
  final segments = [...u.pathSegments];
  if (segments.isNotEmpty && segments.last.isEmpty) segments.removeLast();
  if (segments.length == 5 && _apiVersion.hasMatch(segments[1])) {
    segments.removeAt(1);
  }
  if (segments.length != 4 ||
      segments[0] != 'api' ||
      segments[1] != 'webhooks' ||
      !_id.hasMatch(segments[2]) ||
      !_token.hasMatch(segments[3])) {
    return null;
  }
  return Uri(
    scheme: 'https',
    host: host,
    pathSegments: [...u.pathSegments.where((s) => s.isNotEmpty)],
  );
}

/// A short-timeout HTTP client for [DiscordWebhook] (no proxy, gateway user
/// agent).
http.Client createDiscordHttpClient() => IOClient(
  HttpClient()
    ..connectionTimeout = const Duration(seconds: 5)
    ..idleTimeout = const Duration(seconds: 15)
    ..maxConnectionsPerHost = 2
    ..userAgent = 'yams-hub/$hubVersion'
    ..findProxy = ((_) => 'DIRECT'),
);

/// Sends JSON payloads to one Discord webhook: a short timeout per attempt,
/// retries with backoff on network errors, 5xx and 429 (honouring Discord's
/// `retry_after`), and gives up after [maxAttempts].
final class DiscordWebhook {
  DiscordWebhook({
    required this._url,
    required this._client,
    this.timeout = const Duration(seconds: 10),
    this.maxAttempts = 4,
    this.backoff = const Duration(seconds: 2),
    this.maxRetryAfter = const Duration(seconds: 60),
    Future<void> Function(Duration)? sleep,
    Logger? log,
  }) : _sleep = sleep ?? Future<void>.delayed,
       _log = log ?? Logger('core.notify.discord');

  // Private and never interpolated anywhere.
  final Uri _url;
  final http.Client _client;
  final Future<void> Function(Duration) _sleep;
  final Logger _log;

  /// Per-attempt timeout.
  final Duration timeout;
  final int maxAttempts;

  /// The first retry delay; doubled for each later one.
  final Duration backoff;

  /// Upper bound for a 429 `retry_after` (a longer wait gives up instead).
  final Duration maxRetryAfter;

  /// Posts [payload]. Returns whether Discord accepted it; never throws.
  Future<bool> send(Map<String, Object?> payload) async {
    final body = jsonEncode(payload);
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      Duration? wait;
      String problem;
      try {
        final r = await _client
            .post(
              _url,
              headers: const {'content-type': 'application/json'},
              body: body,
            )
            .timeout(timeout);
        if (r.statusCode >= 200 && r.statusCode < 300) {
          if (attempt > 1) _log.info('Discord alert sent (attempt $attempt)');
          return true;
        }
        problem = 'HTTP ${r.statusCode}';
        if (r.statusCode == 429) {
          wait = _retryAfter(r);
          if (wait == null || wait > maxRetryAfter) {
            _log.warning(
              'Discord alert not sent: rate limited for longer than '
              '${maxRetryAfter.inSeconds} s',
            );
            return false;
          }
        } else if (r.statusCode < 500) {
          // 400/401/403/404: the webhook was deleted or the payload is bad;
          // retrying cannot help.
          _log.warning(
            'Discord alert not sent: Discord answered $problem '
            '(check DISCORD_ALERT_WEBHOOK_URL)',
          );
          return false;
        }
      } on TimeoutException {
        problem = 'timeout';
      } on Exception catch (e) {
        // The exception text may contain the URL: only its type is logged.
        problem = e.runtimeType.toString();
      }
      if (attempt == maxAttempts) {
        _log.warning(
          'Discord alert not sent after $maxAttempts attempts ($problem)',
        );
        return false;
      }
      final delay = wait ?? backoff * pow(2, attempt - 1).toInt();
      _log.fine(
        'Discord alert attempt $attempt failed ($problem); retrying in '
        '${delay.inMilliseconds} ms',
      );
      await _sleep(delay);
    }
    return false;
  }

  /// Discord's `retry_after` (seconds, fractional) from the JSON body, else
  /// the `Retry-After` header.
  static Duration? _retryAfter(http.Response r) {
    num? seconds;
    try {
      final j = jsonDecode(r.body);
      if (j is Map && j['retry_after'] is num) {
        seconds = j['retry_after'] as num;
      }
    } on FormatException {
      // fall back to the header
    }
    seconds ??= num.tryParse(r.headers['retry-after'] ?? '');
    if (seconds == null || seconds < 0 || !seconds.isFinite) return null;
    return Duration(milliseconds: (seconds * 1000).ceil());
  }
}
