/// Updater configuration (ARCHITECTURE §5.17).
///
/// Non-secret settings come from the environment; the bearer token comes only
/// from the file named by `UPDATER_TOKEN_FILE` (`UPDATER_TOKEN='...'`), never
/// from the environment, because Docker copies `environment:` into
/// `Config.Env`, which the read-only socket proxy exposes.
library;

import 'dart:convert';

import 'source_allow_list.dart';

/// `{service}` and deny-list entries must match this (compose service names).
final serviceNamePattern = RegExp(r'^[a-z0-9][a-z0-9_.-]*$');

/// Longest service name the updater accepts.
const maxServiceNameLength = 64;

/// Whether [name] is a syntactically valid compose service name.
bool isValidServiceName(String name) =>
    name.length <= maxServiceNameLength && serviceNamePattern.hasMatch(name);

/// The updater never updates itself, whatever `UPDATER_DENY` says: it would
/// kill its own job half way through.
const selfServiceName = 'yams-hub-updater';

/// `UPDATER_DENY` default: locally built images cannot be pulled, and the
/// pinned socket proxy is only bumped after a template review.
const defaultDenyList = ['yams-hub', 'yams-hub-updater', 'socket-proxy-hub'];

/// Minimum token length in bytes (UTF-8).
const minTokenBytes = 32;

/// A configuration problem. [message] never contains a secret value.
final class UpdaterConfigException implements Exception {
  const UpdaterConfigException(this.message);

  final String message;

  @override
  String toString() => 'UpdaterConfigException: $message';
}

final _tokenFileLine = RegExp(r"^([A-Za-z_][A-Za-z0-9_]*)='([^']*)'$");

/// Extracts `UPDATER_TOKEN` from the token file [contents].
///
/// Blank lines and `#` comments are ignored, other `KEY='value'` lines are
/// allowed and ignored. A line that does not parse is reported by its number
/// only (it may hold the secret). Throws [UpdaterConfigException] when the
/// token is missing or shorter than [minTokenBytes] bytes.
String parseTokenFile(String contents) {
  String? token;
  final lines = contents.split('\n');
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i];
    if (line.endsWith('\r')) line = line.substring(0, line.length - 1);
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
    final m = _tokenFileLine.firstMatch(trimmed);
    if (m == null) {
      throw UpdaterConfigException(
        "token file line ${i + 1} is not of the form KEY='value'",
      );
    }
    if (m[1] == 'UPDATER_TOKEN') token = m[2];
  }
  if (token == null || token.isEmpty) {
    throw const UpdaterConfigException('token file has no UPDATER_TOKEN line');
  }
  final bytes = utf8.encode(token).length;
  if (bytes < minTokenBytes) {
    throw UpdaterConfigException(
      'UPDATER_TOKEN is $bytes bytes; at least $minTokenBytes are required',
    );
  }
  return token;
}

/// Parses `UPDATER_DENY` (comma or whitespace separated). The updater's own
/// service is always denied.
Set<String> parseDenyList(String? raw) {
  final out = <String>{selfServiceName};
  final source = raw ?? defaultDenyList.join(',');
  for (final part in source.split(RegExp(r'[,\s]+'))) {
    final name = part.trim();
    if (name.isEmpty) continue;
    if (!isValidServiceName(name)) {
      throw UpdaterConfigException(
        'UPDATER_DENY entry "$name" is not a valid service name',
      );
    }
    out.add(name);
  }
  return out;
}

/// Immutable updater settings.
final class UpdaterConfig {
  UpdaterConfig({
    required this.token,
    this.port = 8080,
    this.projectName = 'yams',
    this.projectDir = '/opt/yams',
    List<String>? composeFiles,
    Set<String>? deny,
    this.stepTimeout = const Duration(minutes: 15),
    this.allowListRefresh = const Duration(minutes: 10),
    this.tokenFile = defaultTokenFile,
    this.allowedSources,
  }) : composeFiles = List.unmodifiable(
         composeFiles ??
             [
               '$projectDir/docker-compose.yaml',
               '$projectDir/docker-compose.custom.yaml',
             ],
       ),
       deny = Set.unmodifiable(deny ?? parseDenyList(null));

  static const defaultTokenFile = '/run/secrets/updater.env';

  /// Builds the config from [env]. [readFile] returns the contents of a file
  /// or throws (any exception is reported without its text).
  factory UpdaterConfig.fromEnvironment(
    Map<String, String> env, {
    required String Function(String path) readFile,
  }) {
    final tokenFile = _nonEmpty(env['UPDATER_TOKEN_FILE']) ?? defaultTokenFile;
    final String contents;
    try {
      contents = readFile(tokenFile);
    } on Object {
      throw UpdaterConfigException('token file $tokenFile is not readable');
    }
    final token = parseTokenFile(contents);

    final portText = _nonEmpty(env['UPDATER_PORT']) ?? '8080';
    final port = int.tryParse(portText);
    if (port == null || port < 1 || port > 65535) {
      throw const UpdaterConfigException('UPDATER_PORT must be a port number');
    }

    final projectDir = _nonEmpty(env['UPDATER_PROJECT_DIR']) ?? '/opt/yams';
    if (!projectDir.startsWith('/')) {
      throw const UpdaterConfigException(
        'UPDATER_PROJECT_DIR must be an absolute path',
      );
    }
    final projectName = _nonEmpty(env['UPDATER_PROJECT_NAME']) ?? 'yams';
    if (!isValidServiceName(projectName)) {
      throw const UpdaterConfigException(
        'UPDATER_PROJECT_NAME is not a valid compose project name',
      );
    }

    SourceAllowList? allowedSources;
    final sourcesText = _nonEmpty(env['UPDATER_ALLOWED_SOURCES']);
    if (sourcesText != null) {
      try {
        allowedSources = SourceAllowList.parse(sourcesText);
      } on FormatException catch (e) {
        throw UpdaterConfigException('UPDATER_ALLOWED_SOURCES: ${e.message}');
      }
    }

    return UpdaterConfig(
      token: token,
      port: port,
      projectName: projectName,
      projectDir: projectDir,
      deny: parseDenyList(env['UPDATER_DENY']),
      tokenFile: tokenFile,
      allowedSources: allowedSources,
    );
  }

  /// Bearer token shared with the gateway (≥ [minTokenBytes] bytes).
  final String token;
  final String tokenFile;
  final int port;
  final String projectName;
  final String projectDir;
  final List<String> composeFiles;

  /// Services that are never updated (always contains [selfServiceName]).
  final Set<String> deny;
  final Duration stepTimeout;
  final Duration allowListRefresh;

  /// `UPDATER_ALLOWED_SOURCES`: the peers that may connect (loopback always
  /// may). Null when unset: then any peer that reaches the port gets as far
  /// as the token check (the pre-2026-11-08 behaviour; `serve` warns).
  final SourceAllowList? allowedSources;

  @override
  String toString() =>
      'UpdaterConfig(port: $port, project: $projectName, dir: $projectDir, '
      'files: $composeFiles, deny: ${deny.toList()..sort()}, '
      'allowedSources: ${allowedSources ?? 'any (unset)'})';
}

String? _nonEmpty(String? v) {
  final t = v?.trim();
  return t == null || t.isEmpty ? null : t;
}
