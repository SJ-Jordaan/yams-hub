/// Riverpod providers of the settings feature.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:yams_hub/core/app_info.dart';
import 'package:yams_hub/core/auth/token_store.dart';
import 'package:yams_models/yams_models.dart';

import '../data/settings_api.dart';

// --- sessions -----------------------------------------------------------------

/// `GET /auth/sessions`; the argument asks for every user's sessions (admins).
/// Most recently seen first, the current session on top.
final sessionsProvider = FutureProvider.autoDispose.family<List<SessionInfo>, bool>((ref, all) async {
  final sessions = await ref.watch(settingsApiProvider).sessions(all: all);
  return sortSessions(sessions);
});

/// The current session first, then by last activity (newest first).
List<SessionInfo> sortSessions(Iterable<SessionInfo> sessions) => [...sessions]
  ..sort((a, b) {
    if (a.current != b.current) return a.current ? -1 : 1;
    return b.lastSeenAt.compareTo(a.lastSeenAt);
  });

// --- users (admin) --------------------------------------------------------------

/// Hub users (`GET /admin/users`) with the mutations of the user editor.
/// Every mutation patches the list with the gateway's answer.
class UsersController extends AsyncNotifier<List<User>> {
  @override
  Future<List<User>> build() async => sortUsers(await ref.watch(settingsApiProvider).users());

  SettingsApi get _api => ref.read(settingsApiProvider);

  Future<User> create(CreateUserRequest request) async {
    final user = await _api.createUser(request);
    _replace(user);
    // A new link changes which Jellyfin users are taken.
    if (request.jellyfinUserId != null) ref.invalidate(jellyfinUsersProvider);
    return user;
  }

  Future<User> save(String id, UpdateUserRequest request) async {
    final user = await _api.updateUser(id, request);
    _replace(user);
    if (request.jellyfinUserId != null) ref.invalidate(jellyfinUsersProvider);
    return user;
  }

  Future<void> delete(String id) async {
    await _api.deleteUser(id);
    final current = state.value;
    if (current != null) state = AsyncData([for (final u in current) if (u.id != id) u]);
    ref.invalidate(jellyfinUsersProvider);
  }

  void _replace(User user) {
    final current = state.value;
    if (current == null) {
      ref.invalidateSelf();
      return;
    }
    final exists = current.any((u) => u.id == user.id);
    state = AsyncData(
      sortUsers(exists ? [for (final u in current) u.id == user.id ? user : u] : [...current, user]),
    );
  }
}

/// Admins first, then by display name.
List<User> sortUsers(Iterable<User> users) => [...users]
  ..sort((a, b) {
    if (a.role.isAdmin != b.role.isAdmin) return a.role.isAdmin ? -1 : 1;
    return a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase());
  });

final usersProvider = AsyncNotifierProvider.autoDispose<UsersController, List<User>>(UsersController.new);

/// Jellyfin users (`GET /admin/jellyfin-users`) and the "Import into Seerr"
/// action, which replaces the row with the gateway's re-read option.
class JellyfinUsersController extends AsyncNotifier<List<JellyfinUserOption>> {
  @override
  Future<List<JellyfinUserOption>> build() async {
    final options = await ref.watch(settingsApiProvider).jellyfinUsers();
    return [...options]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  }

  Future<JellyfinUserOption> importToSeerr(String jellyfinUserId) async {
    final updated = await ref.read(settingsApiProvider).importToSeerr(jellyfinUserId);
    final current = state.value;
    if (current != null) {
      state = AsyncData([
        for (final o in current) normalizeJellyfinId(o.jellyfinUserId) == normalizeJellyfinId(jellyfinUserId) ? updated : o,
      ]);
    }
    return updated;
  }
}

final jellyfinUsersProvider = AsyncNotifierProvider.autoDispose<JellyfinUsersController, List<JellyfinUserOption>>(
  JellyfinUsersController.new,
);

/// Jellyfin ids compare lowercase without dashes (API.md §2.3).
String normalizeJellyfinId(String id) => id.replaceAll('-', '').toLowerCase();

/// The option of [jellyfinUserId] in [options], if any.
JellyfinUserOption? jellyfinOptionFor(String? jellyfinUserId, List<JellyfinUserOption>? options) {
  if (jellyfinUserId == null || jellyfinUserId.isEmpty || options == null) return null;
  final id = normalizeJellyfinId(jellyfinUserId);
  for (final o in options) {
    if (normalizeJellyfinId(o.jellyfinUserId) == id) return o;
  }
  return null;
}

/// Why a hub user cannot request in Seerr, or null when they can (or when it
/// is unknown because the Jellyfin users did not load). Admins without a link
/// act as Seerr user 1 and are never flagged.
enum SeerrLinkIssue {
  /// A member without a Jellyfin user.
  noJellyfinLink('No Jellyfin link'),

  /// The linked Jellyfin user has no Seerr account (import it).
  noSeerrAccount('No Seerr account');

  const SeerrLinkIssue(this.label);

  final String label;
}

SeerrLinkIssue? seerrLinkIssue(User user, List<JellyfinUserOption>? options) {
  final link = user.jellyfinUserId;
  if (link == null || link.isEmpty) {
    return user.role.isAdmin ? null : SeerrLinkIssue.noJellyfinLink;
  }
  if (options == null) return null;
  final option = jellyfinOptionFor(link, options);
  // A link to a Jellyfin user that no longer exists cannot reach Seerr either.
  if (option == null || option.seerrUserId == null) return SeerrLinkIssue.noSeerrAccount;
  return null;
}

// --- about ----------------------------------------------------------------------

/// App version and build number. Falls back to [hubAppVersion] when the
/// platform cannot tell (tests, unusual web hosting).
final appVersionProvider = FutureProvider<({String version, String? build})>((ref) async {
  try {
    final info = await PackageInfo.fromPlatform();
    final version = info.version.isEmpty ? hubAppVersion : info.version;
    return (version: version, build: info.buildNumber.isEmpty ? null : info.buildNumber);
  } catch (_) {
    return (version: hubAppVersion, build: null);
  }
});

// --- server profiles --------------------------------------------------------------

/// Secure token storage of the server profiles, used to forget the session
/// of a profile that is **not** active (the active one signs out through the
/// auth controller). Core keeps its store private to the token manager, so
/// the settings feature opens its own handle on the same storage.
final profileTokenStoreProvider = Provider<TokenStore>((ref) => createTokenStore(cookieTransport: false));
