/// Gateway configuration: non-secret environment + secrets file + optional
/// policy file (ARCHITECTURE §5.2).
library;

import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:yams_models/yams_models.dart';

import '../core/http/trusted_proxies.dart';
import '../core/log/log.dart';
import 'policy.dart';
import 'secrets_file.dart';

export 'policy.dart';

/// Where a configuration value came from (`check-config` prints it; values are
/// never printed).
enum ConfigSource {
  env,
  file,
  defaultValue;

  String get label => switch (this) {
    env => 'env',
    file => 'file',
    defaultValue => 'default',
  };
}

/// Raised when the configuration is invalid. [errors] never contain secret
/// values.
final class ConfigException implements Exception {
  const ConfigException(this.errors);

  final List<String> errors;

  @override
  String toString() => 'ConfigException: ${errors.join('; ')}';
}

/// One upstream service's connection settings.
final class ServiceConfig {
  const ServiceConfig({
    required this.id,
    required this.url,
    required this.urlSource,
    this.secret,
    this.secretSource,
    this.username,
    this.password,
    this.requiredSecrets = const [],
    this.missingSecrets = const [],
  });

  final ServiceId id;

  /// Base URL (`null` when explicitly set to an empty value).
  final Uri? url;
  final ConfigSource urlSource;

  /// API key or bearer token, when the service uses one.
  final String? secret;
  final ConfigSource? secretSource;

  /// qBittorrent login.
  final String? username;
  final String? password;

  /// Names of the secret variables the service needs.
  final List<String> requiredSecrets;

  /// The subset of [requiredSecrets] that is empty.
  final List<String> missingSecrets;

  /// URL set and every required secret non-empty (ARCHITECTURE §5.2).
  bool get configured => url != null && missingSecrets.isEmpty;
}

/// Immutable gateway configuration built by [ConfigLoader].
final class HubConfig {
  HubConfig({
    required this.port,
    required this.dataDir,
    required this.webDir,
    required this.configFile,
    required this.secretsFile,
    required this.adminUsername,
    required this.adminPasswordHash,
    required this.corsOrigins,
    required this.trustProxy,
    required this.allowedHosts,
    required this.logLevel,
    required this.tzOffset,
    required this.services,
    required this.jellyfinAdminUserId,
    required this.uptimeKumaSlug,
    required this.hostSys,
    required this.hostNetDev,
    required this.recyclarrLogDir,
    required this.policyConfig,
    this.hostVolumeMount = '/volume1',
    this.hostDiskDevice = 'dm-0',
    this.procDir = '/proc',
    this.trustedProxies,
    this.sources = const {},
    this.secretsFileFound = false,
    this.policyFileFound = false,
    this.warnings = const [],
  });

  final int port;
  final String dataDir;
  final String webDir;
  final String configFile;
  final String secretsFile;
  final String adminUsername;

  /// Bootstrap admin hash; only used while the user store is empty and by
  /// `reset-admin`.
  final String? adminPasswordHash;

  /// Exact `scheme://host[:port]` origins allowed for CORS (dev only).
  final List<String> corsOrigins;
  final bool trustProxy;

  /// `YAMS_HUB_TRUSTED_PROXIES`: the socket peers whose `X-Forwarded-For` /
  /// `X-Forwarded-Proto` are believed when [trustProxy] is on (null:
  /// loopback only).
  final TrustedProxies? trustedProxies;

  /// Extra allowed `Host` header values (lower case, without port).
  final List<String> allowedHosts;
  final Level logLevel;

  /// Fixed local-time offset (SAST: +02:00).
  final Duration tzOffset;
  final Map<ServiceId, ServiceConfig> services;

  /// `JELLYFIN_ADMIN_USER_ID`, or null for auto-detection.
  final String? jellyfinAdminUserId;
  final String uptimeKumaSlug;
  final String hostSys;
  final String hostNetDev;
  final String recyclarrLogDir;

  /// `HOST_VOLUME_MOUNT`: the host path the data volume's usage is reported
  /// as (the gateway measures `statvfs` of its data dir, which lives on it).
  final String hostVolumeMount;

  /// `HOST_DISK_DEVICE`: the `/proc/diskstats` device of the data volume
  /// (empty: no disk I/O).
  final String hostDiskDevice;

  /// Directory of the host-global procfs files (the container's own `/proc`).
  final String procDir;
  final PolicyConfig policyConfig;

  /// Which source each variable came from (keys are variable names).
  final Map<String, ConfigSource> sources;
  final bool secretsFileFound;
  final bool policyFileFound;

  /// Non-fatal problems (logged at start-up, printed by `check-config`).
  final List<String> warnings;

  HubPolicy get policy => policyConfig.policy;
  AuthSettings get auth => policyConfig.auth;
  AlertThresholds get alerts => policyConfig.alerts;
  ImageCacheSettings get imageCache => policyConfig.imageCache;
  List<Uri> get publicUrls => policyConfig.publicUrls;
  Map<ExternalApp, ExternalAppConfig> get externalApps =>
      policyConfig.externalApps;
  List<String> get remoteImageHosts => policyConfig.remoteImageHosts;

  /// The settings of [id]. Every [ServiceId] except `unknown` and `host` has
  /// an entry.
  ServiceConfig service(ServiceId id) =>
      services[id] ??
      ServiceConfig(id: id, url: null, urlSource: ConfigSource.defaultValue);

  bool isConfigured(ServiceId id) =>
      id == ServiceId.host || (services[id]?.configured ?? false);

  /// The image cache directory.
  String get imageCacheDir => p.join(dataDir, 'cache', 'images');

  /// A copy with some fields replaced (tests).
  HubConfig copyWith({
    String? dataDir,
    String? webDir,
    String? procDir,
    String? hostNetDev,
    String? hostSys,
    String? recyclarrLogDir,
    PolicyConfig? policyConfig,
    Map<ServiceId, ServiceConfig>? services,
    List<String>? corsOrigins,
    bool? trustProxy,
    TrustedProxies? trustedProxies,
  }) => HubConfig(
    port: port,
    dataDir: dataDir ?? this.dataDir,
    webDir: webDir ?? this.webDir,
    configFile: configFile,
    secretsFile: secretsFile,
    adminUsername: adminUsername,
    adminPasswordHash: adminPasswordHash,
    corsOrigins: corsOrigins ?? this.corsOrigins,
    trustProxy: trustProxy ?? this.trustProxy,
    trustedProxies: trustedProxies ?? this.trustedProxies,
    allowedHosts: allowedHosts,
    logLevel: logLevel,
    tzOffset: tzOffset,
    services: services ?? this.services,
    jellyfinAdminUserId: jellyfinAdminUserId,
    uptimeKumaSlug: uptimeKumaSlug,
    hostSys: hostSys ?? this.hostSys,
    hostNetDev: hostNetDev ?? this.hostNetDev,
    recyclarrLogDir: recyclarrLogDir ?? this.recyclarrLogDir,
    hostVolumeMount: hostVolumeMount,
    hostDiskDevice: hostDiskDevice,
    procDir: procDir ?? this.procDir,
    policyConfig: policyConfig ?? this.policyConfig,
    sources: sources,
    secretsFileFound: secretsFileFound,
    policyFileFound: policyFileFound,
    warnings: warnings,
  );
}

/// How one service is configured from the environment.
final class _ServiceVars {
  const _ServiceVars(
    this.id,
    this.urlVar,
    this.defaultUrl, {
    this.secretVar,
    this.loginVars = false,
  });

  final ServiceId id;
  final String urlVar;
  final String defaultUrl;
  final String? secretVar;

  /// qBittorrent: `QBIT_USERNAME` + `QBIT_PASSWORD`.
  final bool loginVars;
}

const _serviceVars = [
  _ServiceVars(
    ServiceId.sonarr,
    'SONARR_URL',
    'http://sonarr:8989',
    secretVar: 'SONARR_API_KEY',
  ),
  _ServiceVars(
    ServiceId.radarr,
    'RADARR_URL',
    'http://radarr:7878',
    secretVar: 'RADARR_API_KEY',
  ),
  _ServiceVars(
    ServiceId.prowlarr,
    'PROWLARR_URL',
    'http://prowlarr:9696',
    secretVar: 'PROWLARR_API_KEY',
  ),
  _ServiceVars(
    ServiceId.bazarr,
    'BAZARR_URL',
    'http://bazarr:6767',
    secretVar: 'BAZARR_API_KEY',
  ),
  _ServiceVars(
    ServiceId.seerr,
    'SEERR_URL',
    'http://seerr:5055',
    secretVar: 'SEERR_API_KEY',
  ),
  _ServiceVars(
    ServiceId.jellyfin,
    'JELLYFIN_URL',
    'http://jellyfin:8096',
    secretVar: 'JELLYFIN_API_KEY',
  ),
  _ServiceVars(
    ServiceId.jellystat,
    'JELLYSTAT_URL',
    'http://jellystat:3000',
    secretVar: 'JELLYSTAT_API_KEY',
  ),
  _ServiceVars(
    ServiceId.qbittorrent,
    'QBIT_URL',
    'http://gluetun:8081',
    loginVars: true,
  ),
  _ServiceVars(ServiceId.gluetun, 'GLUETUN_URL', 'http://gluetun:8000'),
  _ServiceVars(ServiceId.docker, 'DOCKER_URL', 'http://socket-proxy-hub:2375'),
  _ServiceVars(
    ServiceId.watchtower,
    'WATCHTOWER_URL',
    'http://watchtower:8080',
    secretVar: 'WATCHTOWER_TOKEN',
  ),
  _ServiceVars(
    ServiceId.updater,
    'UPDATER_URL',
    'http://yams-hub-updater:8080',
    secretVar: 'UPDATER_TOKEN',
  ),
  _ServiceVars(
    ServiceId.uptimeKuma,
    'UPTIME_KUMA_URL',
    'http://uptime-kuma:3001',
  ),
  _ServiceVars(
    ServiceId.audiobookshelf,
    'ABS_URL',
    'http://audiobookshelf:80',
    secretVar: 'ABS_API_KEY',
  ),
  _ServiceVars(
    ServiceId.kavita,
    'KAVITA_URL',
    'http://kavita:5000',
    secretVar: 'KAVITA_API_KEY',
  ),
  _ServiceVars(ServiceId.shelfmark, 'SHELFMARK_URL', 'http://shelfmark:8084'),
];

/// Variables that hold secrets and belong in the secrets file.
const secretVariables = {
  'YAMS_HUB_ADMIN_PASSWORD_HASH',
  'SONARR_API_KEY',
  'RADARR_API_KEY',
  'PROWLARR_API_KEY',
  'BAZARR_API_KEY',
  'SEERR_API_KEY',
  'JELLYFIN_API_KEY',
  'JELLYFIN_ADMIN_USER_ID',
  'JELLYSTAT_API_KEY',
  'QBIT_USERNAME',
  'QBIT_PASSWORD',
  'WATCHTOWER_TOKEN',
  'UPDATER_TOKEN',
  'ABS_API_KEY',
  'KAVITA_API_KEY',
};

/// Builds a [HubConfig].
abstract final class ConfigLoader {
  /// Loads the configuration from [env] merged with the secrets file
  /// [secretsFileContents] (its values win) and the policy file
  /// [policyFileContents]. A null content means the file does not exist.
  ///
  /// Throws [ConfigException] listing every problem.
  static HubConfig load(
    Map<String, String> env, {
    String? secretsFileContents,
    String? policyFileContents,
  }) {
    final errors = <String>[];
    final warnings = <String>[];

    var fileValues = const <String, String>{};
    if (secretsFileContents != null) {
      try {
        fileValues = parseSecretsFile(secretsFileContents);
      } on SecretsFileException catch (e) {
        errors.add(e.message);
      }
    }

    final sources = <String, ConfigSource>{};
    String? value(String key) {
      if (fileValues.containsKey(key)) {
        sources[key] = ConfigSource.file;
        return fileValues[key];
      }
      if (env.containsKey(key)) {
        sources[key] = ConfigSource.env;
        return env[key];
      }
      return null;
    }

    String setting(String key, String fallback) {
      final v = value(key);
      if (v == null) {
        sources[key] = ConfigSource.defaultValue;
        return fallback;
      }
      return v.trim();
    }

    for (final key in secretVariables) {
      if (env.containsKey(key) &&
          !fileValues.containsKey(key) &&
          (env[key] ?? '').isNotEmpty) {
        warnings.add(
          '$key is set in the environment; move it to the secrets file '
          '(environment values are visible in the container config)',
        );
      }
    }

    final portText = setting('YAMS_HUB_PORT', '8080');
    final port = int.tryParse(portText);
    if (port == null || port < 1 || port > 65535) {
      errors.add('YAMS_HUB_PORT must be a port number');
    }

    final dataDir = setting('YAMS_HUB_DATA_DIR', '/data');
    if (dataDir.isEmpty) errors.add('YAMS_HUB_DATA_DIR must not be empty');
    final webDir = setting('YAMS_HUB_WEB_DIR', '/srv/web');
    final configFile = setting(
      'YAMS_HUB_CONFIG_FILE',
      p.join(dataDir.isEmpty ? '/data' : dataDir, 'yams-hub.yaml'),
    );
    final secretsFile = setting(
      'YAMS_HUB_SECRETS_FILE',
      '/run/secrets/yams-hub.env',
    );

    final adminUsername = setting(
      'YAMS_HUB_ADMIN_USERNAME',
      'admin',
    ).toLowerCase();
    if (!RegExp(r'^[a-z0-9._-]{2,32}$').hasMatch(adminUsername)) {
      errors.add('YAMS_HUB_ADMIN_USERNAME must match ^[a-z0-9._-]{2,32}\$');
    }
    final adminHash = value('YAMS_HUB_ADMIN_PASSWORD_HASH');

    final corsOrigins = <String>[];
    final corsText = setting('YAMS_HUB_CORS_ORIGINS', '');
    for (final raw in corsText.split(',')) {
      final o = raw.trim();
      if (o.isEmpty) continue;
      final normalised = normaliseCorsOrigin(o);
      if (normalised == null) {
        errors.add(
          'YAMS_HUB_CORS_ORIGINS: "$o" is not an exact http(s)://host[:port] origin',
        );
      } else {
        corsOrigins.add(normalised);
      }
    }

    final trustProxy = _bool(setting('YAMS_HUB_TRUST_PROXY', 'false'));
    if (trustProxy == null) {
      errors.add('YAMS_HUB_TRUST_PROXY must be true or false');
    }
    final proxiesText = setting('YAMS_HUB_TRUSTED_PROXIES', '');
    final trustedProxies = proxiesText.isEmpty
        ? null
        : TrustedProxies.parse(proxiesText, errors);
    if (trustProxy == true && trustedProxies == null) {
      warnings.add(
        'YAMS_HUB_TRUST_PROXY is on but YAMS_HUB_TRUSTED_PROXIES is unset: '
        'X-Forwarded-For is only believed from loopback peers',
      );
    }

    final allowedHosts = [
      for (final h in setting('YAMS_HUB_ALLOWED_HOSTS', '').split(','))
        if (h.trim().isNotEmpty) h.trim().toLowerCase(),
    ];

    final levelText = setting('YAMS_HUB_LOG_LEVEL', 'info');
    final level = parseLogLevel(levelText);
    if (level == null) {
      errors.add('YAMS_HUB_LOG_LEVEL must be fine, info, warning or severe');
    }

    final tzText = setting('YAMS_HUB_TZ_OFFSET', '+02:00');
    final tz = parseTzOffset(tzText);
    if (tz == null) errors.add('YAMS_HUB_TZ_OFFSET must look like +02:00');

    final services = <ServiceId, ServiceConfig>{};
    for (final sv in _serviceVars) {
      final urlRaw = value(sv.urlVar);
      final urlSource = sources[sv.urlVar] ?? ConfigSource.defaultValue;
      final urlText = (urlRaw ?? sv.defaultUrl).trim();
      Uri? url;
      if (urlText.isNotEmpty) {
        url = _serviceUrl(urlText);
        if (url == null) {
          errors.add('${sv.urlVar} must be an absolute http(s) URL');
        }
      }
      final required = <String>[];
      final missing = <String>[];
      String? secret;
      ConfigSource? secretSource;
      String? username;
      String? password;
      if (sv.secretVar case final key?) {
        required.add(key);
        secret = value(key);
        secretSource = sources[key];
        if (secret == null || secret.isEmpty) {
          secret = null;
          missing.add(key);
        }
      }
      if (sv.loginVars) {
        required.addAll(const ['QBIT_USERNAME', 'QBIT_PASSWORD']);
        username = value('QBIT_USERNAME');
        password = value('QBIT_PASSWORD');
        secretSource = sources['QBIT_PASSWORD'];
        if (username == null || username.isEmpty) missing.add('QBIT_USERNAME');
        if (password == null || password.isEmpty) missing.add('QBIT_PASSWORD');
      }
      if (sv.id == ServiceId.updater && secret != null && secret.length < 32) {
        warnings.add(
          'UPDATER_TOKEN is shorter than 32 bytes; the updater is treated as '
          'not configured',
        );
        missing.add('UPDATER_TOKEN');
      }
      services[sv.id] = ServiceConfig(
        id: sv.id,
        url: url,
        urlSource: urlSource,
        secret: secret,
        secretSource: secretSource,
        username: username,
        password: password,
        requiredSecrets: required,
        missingSecrets: missing,
      );
    }

    var jellyfinAdmin = value('JELLYFIN_ADMIN_USER_ID')?.trim();
    if (jellyfinAdmin != null) {
      if (jellyfinAdmin.isEmpty) {
        jellyfinAdmin = null;
      } else {
        final n = normaliseJellyfinId(jellyfinAdmin);
        if (n == null) {
          errors.add(
            'JELLYFIN_ADMIN_USER_ID must be a 32-hex Jellyfin user id',
          );
        }
        jellyfinAdmin = n;
      }
    }

    final slug = setting('UPTIME_KUMA_SLUG', 'zenith');
    if (!RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(slug)) {
      errors.add('UPTIME_KUMA_SLUG must be a status page slug');
    }

    final volumeMount = setting('HOST_VOLUME_MOUNT', '/volume1');
    if (volumeMount.isEmpty) errors.add('HOST_VOLUME_MOUNT must not be empty');

    var policyConfig = PolicyConfig();
    if (policyFileContents != null) {
      final policyErrors = <String>[];
      policyConfig = PolicyConfig.parse(policyFileContents, policyErrors);
      errors.addAll(policyErrors.map((e) => 'policy: $e'));
    }

    if (errors.isNotEmpty) throw ConfigException(errors);

    return HubConfig(
      port: port!,
      dataDir: dataDir,
      webDir: webDir,
      configFile: configFile,
      secretsFile: secretsFile,
      adminUsername: adminUsername,
      adminPasswordHash: (adminHash == null || adminHash.isEmpty)
          ? null
          : adminHash,
      corsOrigins: List.unmodifiable(corsOrigins),
      trustProxy: trustProxy!,
      trustedProxies: trustedProxies,
      allowedHosts: List.unmodifiable(allowedHosts),
      logLevel: level!,
      tzOffset: tz!,
      services: Map.unmodifiable(services),
      jellyfinAdminUserId: jellyfinAdmin,
      uptimeKumaSlug: slug,
      hostSys: setting('HOST_SYS', '/sys'),
      hostNetDev: setting('HOST_NET_DEV', '/host/proc/1/net/dev'),
      recyclarrLogDir: setting('RECYCLARR_LOG_DIR', '/host/recyclarr-logs'),
      hostVolumeMount: volumeMount,
      hostDiskDevice: setting('HOST_DISK_DEVICE', 'dm-0'),
      policyConfig: policyConfig,
      sources: Map.unmodifiable(sources),
      secretsFileFound: secretsFileContents != null,
      policyFileFound: policyFileContents != null,
      warnings: List.unmodifiable(warnings),
    );
  }

  /// Loads from the process environment and the files it names.
  static HubConfig loadFromSystem([Map<String, String>? environment]) {
    final env = environment ?? Platform.environment;
    final secretsPath =
        env['YAMS_HUB_SECRETS_FILE'] ?? '/run/secrets/yams-hub.env';
    String? secrets;
    final secretsFile = File(secretsPath);
    try {
      if (secretsFile.existsSync()) secrets = secretsFile.readAsStringSync();
    } on FileSystemException catch (e) {
      throw ConfigException([
        'secrets file $secretsPath is not readable (${e.osError?.message ?? 'error'})',
      ]);
    }
    // The secrets file may move the data dir; resolve the policy path the same
    // way load() does.
    var policyPath = env['YAMS_HUB_CONFIG_FILE'];
    if (policyPath == null) {
      var dataDir = env['YAMS_HUB_DATA_DIR'] ?? '/data';
      if (secrets != null) {
        try {
          dataDir = parseSecretsFile(secrets)['YAMS_HUB_DATA_DIR'] ?? dataDir;
        } on SecretsFileException {
          // reported by load()
        }
      }
      policyPath = p.join(dataDir, 'yams-hub.yaml');
    }
    String? policy;
    final policyFile = File(policyPath);
    try {
      if (policyFile.existsSync()) policy = policyFile.readAsStringSync();
    } on FileSystemException {
      throw ConfigException(['policy file $policyPath is not readable']);
    }
    return load(env, secretsFileContents: secrets, policyFileContents: policy);
  }
}

bool? _bool(String v) => switch (v.trim().toLowerCase()) {
  'true' || '1' || 'yes' => true,
  'false' || '0' || 'no' || '' => false,
  _ => null,
};

Uri? _serviceUrl(String text) {
  final u = Uri.tryParse(text);
  if (u == null || !(u.scheme == 'http' || u.scheme == 'https')) return null;
  if (u.host.isEmpty || u.hasQuery || u.hasFragment || u.userInfo.isNotEmpty) {
    return null;
  }
  // Drop a trailing slash so paths can be appended segment-wise.
  final segments = [
    for (final s in u.pathSegments)
      if (s.isNotEmpty) s,
  ];
  return u.replace(pathSegments: segments);
}

/// Validates a CORS origin and returns it normalised (lower-case scheme and
/// host), or null when it is not an exact `http(s)://host[:port]` origin.
/// `*`, `null`, paths, queries and other schemes are rejected.
String? normaliseCorsOrigin(String origin) {
  if (origin == '*' || origin.toLowerCase() == 'null') return null;
  final u = Uri.tryParse(origin);
  if (u == null || !(u.scheme == 'http' || u.scheme == 'https')) return null;
  if (u.host.isEmpty || u.host.contains('*')) return null;
  if (u.userInfo.isNotEmpty || u.hasQuery || u.hasFragment) return null;
  if (u.path.isNotEmpty) return null;
  final scheme = u.scheme.toLowerCase();
  final host = u.host.toLowerCase();
  final h = host.contains(':') ? '[$host]' : host;
  return u.hasPort ? '$scheme://$h:${u.port}' : '$scheme://$h';
}

/// Parses `+02:00` / `-05:30` / `Z`.
Duration? parseTzOffset(String text) {
  final t = text.trim();
  if (t == 'Z' || t == 'UTC') return Duration.zero;
  final m = RegExp(r'^([+-])(\d{2}):?(\d{2})$').firstMatch(t);
  if (m == null) return null;
  final h = int.parse(m[2]!);
  final min = int.parse(m[3]!);
  if (h > 14 || min > 59) return null;
  final d = Duration(hours: h, minutes: min);
  return m[1] == '-' ? -d : d;
}

final _jellyfinId = RegExp(r'^[0-9a-f]{32}$');

/// Normalises a Jellyfin GUID (dashed or not, any case) to 32 lower-case hex
/// characters; null when it is not one.
String? normaliseJellyfinId(String? id) {
  if (id == null) return null;
  final n = id.trim().toLowerCase().replaceAll('-', '');
  return _jellyfinId.hasMatch(n) ? n : null;
}
