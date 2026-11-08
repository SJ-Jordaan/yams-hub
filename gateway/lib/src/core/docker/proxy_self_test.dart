/// Start-up check that `socket-proxy-hub` refuses writes (ARCHITECTURE §5.16).
library;

import 'package:logging/logging.dart';
import 'package:yams_models/yams_models.dart';

import '../clock.dart';
import '../http/api_exception.dart';
import '../upstream/upstream_client.dart';
import '../upstream/upstream_exception.dart';

final _log = Logger('core.docker.selftest');

/// Outcome of the last self-test.
enum ProxySelfTestState {
  /// Not run yet.
  pending,

  /// Every forbidden request got 403.
  passed,

  /// A forbidden request was not refused: container actions are disabled.
  failed,

  /// The proxy could not be reached (or Docker is not configured).
  unreachable,
}

/// Probes `POST /containers/create`, `POST /images/create` and
/// `DELETE /containers/<nonexistent>`; each must be refused with 403. Any
/// other answer disables every container action until a later run passes.
/// The probes cannot do harm even if they get through: the names do not exist
/// and the create body is invalid.
final class ProxySelfTest {
  ProxySelfTest(this._docker, this._clock);

  final DockerClient _docker;
  final Clock _clock;
  ProxySelfTestState _state = ProxySelfTestState.pending;
  DateTime? _ranAt;

  ProxySelfTestState get state => _state;
  DateTime? get ranAt => _ranAt;

  /// Container actions are allowed only after a passed self-test.
  bool get actionsAllowed => _state == ProxySelfTestState.passed;

  /// The health message for a failed test, else null.
  String? get healthMessage => _state == ProxySelfTestState.failed
      ? 'socket-proxy-hub allows writes it should refuse; container actions disabled'
      : null;

  /// Throws `503 service_not_configured` unless container actions are
  /// allowed.
  void ensureActionsAllowed() {
    if (actionsAllowed) return;
    throw ApiException.serviceNotConfigured(
      ServiceId.docker,
      _state == ProxySelfTestState.failed
          ? 'Docker proxy is not restricted; container actions disabled'
          : 'The Docker proxy self-test has not passed; container actions are disabled',
    );
  }

  Future<ProxySelfTestState> run() async {
    _ranAt = _clock.now();
    if (!_docker.configured) return _state = ProxySelfTestState.unreachable;
    final probes = <(String, String, Map<String, Object?>?, Object?)>[
      ('POST', '/containers/create', null, const <String, Object?>{}),
      (
        'POST',
        '/images/create',
        {'fromImage': 'yams-hub-selftest-nonexistent'},
        null,
      ),
      ('DELETE', '/containers/yams-hub-selftest-nonexistent', null, null),
    ];
    try {
      for (final (method, path, query, body) in probes) {
        final r = await _docker.send(
          method,
          path,
          query: query,
          jsonBody: body,
          timeout: const Duration(seconds: 5),
          maxBytes: 64 * 1024,
        );
        if (r.status != 403) {
          _log.severe(
            'socket-proxy-hub answered $method ${_docker.pathPrefix}$path with '
            '${r.status} instead of 403; container actions disabled',
          );
          return _state = ProxySelfTestState.failed;
        }
      }
    } on UpstreamException catch (e) {
      _log.warning('Docker proxy self-test could not run: $e');
      return _state = ProxySelfTestState.unreachable;
    }
    if (_state != ProxySelfTestState.passed) {
      _log.info('Docker proxy self-test passed');
    }
    return _state = ProxySelfTestState.passed;
  }
}
