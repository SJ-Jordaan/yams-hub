/// Server profiles persisted in SharedPreferences (ARCHITECTURE §7.5).
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yams_models/yams_models.dart';

import '../settings/app_settings.dart';
import 'hosting.dart';
import 'server_profile.dart';

@immutable
class ServerStoreState {
  const ServerStoreState({this.profiles = const [], this.activeId});

  final List<ServerProfile> profiles;
  final String? activeId;

  /// The active profile; the first profile when [activeId] is stale.
  ServerProfile? get active {
    for (final p in profiles) {
      if (p.id == activeId) return p;
    }
    return profiles.isEmpty ? null : profiles.first;
  }

  ServerProfile? byId(String id) {
    for (final p in profiles) {
      if (p.id == id) return p;
    }
    return null;
  }

  JsonMap toJson() => compactJson({
    'profiles': [for (final p in profiles) p.toJson()],
    'activeId': activeId,
  });

  static ServerStoreState fromJson(JsonMap j) => ServerStoreState(
    profiles: readList(j['profiles'], ServerProfile.fromJson),
    activeId: readString(j['activeId']),
  );
}

/// Owns the server profiles. On the gateway-served web build it holds the
/// single implicit profile of the page origin and persists nothing.
class ServerStore extends Notifier<ServerStoreState> {
  static const storageKey = 'servers.v1';

  /// Reads the stored profiles (used by `main()` before the provider exists).
  static ServerStoreState readFrom(SharedPreferences prefs) {
    final raw = prefs.getString(storageKey);
    if (raw == null) return const ServerStoreState();
    try {
      final map = readMap(jsonDecode(raw));
      return map == null ? const ServerStoreState() : ServerStoreState.fromJson(map);
    } on FormatException {
      return const ServerStoreState();
    }
  }

  @override
  ServerStoreState build() {
    if (ref.watch(hostingModeProvider) == HostingMode.gatewayWeb) {
      final profile = implicitWebProfile(Uri.base);
      return ServerStoreState(profiles: [profile], activeId: profile.id);
    }
    return readFrom(ref.watch(sharedPreferencesProvider));
  }

  bool get _persistent => ref.read(hostingModeProvider).hasServerProfiles;

  void _set(ServerStoreState next) {
    state = next;
    if (_persistent) {
      ref.read(sharedPreferencesProvider).setString(storageKey, jsonEncode(next.toJson()));
    }
  }

  /// Adds or replaces [profile]; makes it active when [activate] or when it
  /// is the first profile.
  void upsert(ServerProfile profile, {bool activate = false}) {
    final exists = state.byId(profile.id) != null;
    final profiles = exists
        ? [for (final p in state.profiles) p.id == profile.id ? profile : p]
        : [...state.profiles, profile];
    _set(
      ServerStoreState(
        profiles: profiles,
        activeId: activate || state.activeId == null ? profile.id : state.activeId,
      ),
    );
  }

  /// Removes a profile (the next one becomes active).
  void remove(String id) {
    final profiles = [for (final p in state.profiles) if (p.id != id) p];
    final activeId = state.activeId == id
        ? (profiles.isEmpty ? null : profiles.first.id)
        : state.activeId;
    _set(ServerStoreState(profiles: profiles, activeId: activeId));
  }

  void setActive(String id) {
    if (state.byId(id) == null) return;
    _set(ServerStoreState(profiles: state.profiles, activeId: id));
  }

  /// Records the URL that answered (and the instance id learned from it).
  void recordGoodUrl(String id, Uri url, {String? instanceId}) {
    final p = state.byId(id);
    if (p == null) return;
    if (p.lastGoodUrl == url && (instanceId == null || p.instanceId == instanceId)) return;
    upsert(p.copyWith(lastGoodUrl: url, instanceId: p.instanceId ?? instanceId));
  }

  /// A new random profile id.
  static String newId() => 'p_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
}

final serverStoreProvider = NotifierProvider<ServerStore, ServerStoreState>(ServerStore.new);

/// The active profile, or null when none is configured.
final activeProfileProvider = Provider<ServerProfile?>(
  (ref) => ref.watch(serverStoreProvider.select((s) => s.active)),
);
