import 'dart:io';

import 'package:test/test.dart';
import 'package:yams_models/yams_models.dart';

/// Names that must never be public in yams_models (ARCHITECTURE §4): they
/// clash with Flutter, Dart or cached_network_image exports.
const _reserved = {
  'Page',
  'Container',
  'Route',
  'Text',
  'Image',
  'Icon',
  'Badge',
  'Card',
  'Chip',
  'Tab',
  'Action',
  'DownloadProgress',
  'Size',
  'Key',
  'State',
  'Filter',
  'Category',
  'Tag',
  'Summary',
  'Counts',
  'Status',
  'Health',
  'Link',
};

/// Reserved for core files only.
const _coreOnly = {'User', 'Job', 'Alert'};

const _coreFiles = {
  'json',
  'common',
  'auth',
  'server',
  'dashboard',
  'arr_common',
};

const _featureFiles = {
  'requests',
  'library',
  'activity',
  'calendar',
  'indexers',
  'subtitles',
  'containers',
  'system',
  'media',
};

final _publicDeclaration = RegExp(
  r'^(?:(?:abstract|final|sealed|base|interface|mixin)\s+)*'
  r'(?:class|enum|mixin|typedef|extension(?:\s+type)?)\s+([A-Z]\w*)',
  multiLine: true,
);

void main() {
  test('the library exports every core type', () {
    // Compile-time check that the barrel exposes the core API.
    final types = <Type>[
      ApiError,
      PagedList,
      CursorPage,
      ItemList,
      Section,
      SectionStatus,
      Alert,
      ServiceId,
      ExternalApp,
      ExternalLink,
      Job,
      JobStep,
      CommandRef,
      User,
      Role,
      LoginRequest,
      LoginResponse,
      TokenPair,
      SessionInfo,
      MeResponse,
      SeerrQuota,
      QuotaInfo,
      CreateUserRequest,
      UpdateUserRequest,
      JellyfinUserOption,
      AuditEntry,
      ChangePasswordRequest,
      ServerPing,
      ServerConfig,
      HealthReport,
      ServiceHealth,
      DashboardResponse,
      ArrService,
      QualityInfo,
      MediaFileInfo,
      HealthMessage,
      ArrHistoryType,
      ArrHistoryItem,
    ];
    expect(types, hasLength(38));
  });

  test('every src file exists and is exported', () {
    final barrel = File('lib/yams_models.dart').readAsStringSync();
    for (final f in {..._coreFiles, ..._featureFiles}) {
      expect(barrel, contains("export 'src/$f.dart';"), reason: f);
      expect(File('lib/src/$f.dart').existsSync(), isTrue, reason: f);
    }
  });

  test('no reserved public names; core-only names stay in core', () {
    for (final f in {..._coreFiles, ..._featureFiles}) {
      final src = File('lib/src/$f.dart').readAsStringSync();
      for (final m in _publicDeclaration.allMatches(src)) {
        final name = m.group(1)!;
        expect(
          _reserved,
          isNot(contains(name)),
          reason: '$f.dart declares $name',
        );
        if (_featureFiles.contains(f)) {
          expect(
            _coreOnly,
            isNot(contains(name)),
            reason: '$f.dart declares $name',
          );
        }
      }
    }
  });

  test('every core enum parses unknown strings to unknown', () {
    final parsers = <String, Enum Function(Object?)>{
      'ServiceId': ServiceId.fromJson,
      'ExternalApp': ExternalApp.fromJson,
      'SectionState': SectionState.fromJson,
      'AlertSeverity': AlertSeverity.fromJson,
      'JobStatus': JobStatus.fromJson,
      'CommandStatus': CommandStatus.fromJson,
      'CommandResult': CommandResult.fromJson,
      'Role': Role.fromJson,
      'ClientPlatform': ClientPlatform.fromJson,
      'AuthTransport': AuthTransport.fromJson,
      'AuditOutcome': AuditOutcome.fromJson,
      'ServiceHealthStatus': ServiceHealthStatus.fromJson,
      'ArrService': ArrService.fromJson,
      'HealthMessageType': HealthMessageType.fromJson,
      'ArrHistoryType': ArrHistoryType.fromJson,
      'ArrReleaseSource': ArrReleaseSource.fromJson,
    };
    parsers.forEach((name, parse) {
      for (final bad in <Object?>['__nope__', '', null, 42, true]) {
        expect(parse(bad).name, 'unknown', reason: '$name($bad)');
      }
    });

    // Every enum declared in a core file must be covered above.
    for (final f in _coreFiles) {
      final src = File('lib/src/$f.dart').readAsStringSync();
      for (final m in RegExp(
        r'^enum\s+(\w+)',
        multiLine: true,
      ).allMatches(src)) {
        expect(
          parsers.keys,
          contains(m.group(1)),
          reason: '$f.dart enum ${m.group(1)}',
        );
      }
    }
  });
}
