/// Every app route (APP.md §1) and the [AppPaths] helpers (ARCHITECTURE §7.3).
///
/// Features never build cross-feature route strings by hand: they call
/// `AppPaths.seriesDetail(54)`, `AppPaths.torrent(hash)`, ... Query values are
/// URI-encoded and null arguments are omitted.
library;

/// Root paths of the top-level destinations, in shell branch order.
abstract final class RootPaths {
  static const home = '/home';
  static const requests = '/requests';
  static const library = '/library';
  static const activity = '/activity';
  static const calendar = '/calendar';
  static const media = '/media';
  static const containers = '/containers';
  static const indexers = '/indexers';
  static const subtitles = '/subtitles';
  static const system = '/system';
  static const settings = '/settings';
  static const more = '/more';

  static const onboarding = '/onboarding';
  static const login = '/login';

  /// Branch index of each shell root (StatefulShellRoute order).
  static const branches = [
    home,
    requests,
    library,
    activity,
    calendar,
    media,
    containers,
    indexers,
    subtitles,
    system,
    settings,
    more,
  ];
}

abstract final class AppPaths {
  static String _q(String path, Map<String, Object?> query) {
    final params = {
      for (final e in query.entries)
        if (e.value != null && e.value.toString().isNotEmpty) e.key: e.value.toString(),
    };
    if (params.isEmpty) return path;
    return Uri(path: path, queryParameters: params).toString();
  }

  static String _seg(String value) => Uri.encodeComponent(value);

  // --- outside the shell -------------------------------------------------------
  static String onboarding() => RootPaths.onboarding;
  static String login({String? from}) => _q(RootPaths.login, {'from': from});

  // --- home --------------------------------------------------------------------
  static String home() => RootPaths.home;
  static String webApps() => '${RootPaths.home}/apps';

  // --- requests ----------------------------------------------------------------
  static String requests() => RootPaths.requests;
  static String requestsSearch(String q) => _q('${RootPaths.requests}/search', {'q': q});
  static String requestsDiscover(String slider) => '${RootPaths.requests}/discover/${_seg(slider)}';
  static String title(String mediaType, int tmdbId) =>
      '${RootPaths.requests}/title/${_seg(mediaType)}/$tmdbId';
  static String requestsList({String? tab}) => _q('${RootPaths.requests}/list', {'tab': tab});
  static String requestDetail(int id) => '${RootPaths.requests}/list/$id';
  static String issues() => '${RootPaths.requests}/issues';
  static String issueDetail(int id) => '${RootPaths.requests}/issues/$id';

  // --- library -----------------------------------------------------------------
  static String library({String? tab}) => _q(RootPaths.library, {'tab': tab});
  static String seriesDetail(int id) => '${RootPaths.library}/tv/$id';
  static String seasonDetail(int id, int n) => '${RootPaths.library}/tv/$id/season/$n';
  static String movieDetail(int id) => '${RootPaths.library}/movies/$id';
  static String libraryAdd({String? kind, String? term}) =>
      _q('${RootPaths.library}/add', {'kind': kind, 'term': term});
  static String libraryHistory(String service, int id) =>
      '${RootPaths.library}/history/${_seg(service)}/$id';

  // --- activity ----------------------------------------------------------------
  /// `/activity?tab=&import=`; [importKey] opens the manual-import sheet of
  /// that queue item (the target of `queue.import.<key>` alerts).
  static String activity({String? tab, String? importKey}) =>
      _q(RootPaths.activity, {'tab': tab, 'import': importKey});
  static String torrent(String hash) => '${RootPaths.activity}/torrent/${_seg(hash)}';
  static String activityTransfer() => '${RootPaths.activity}/transfer';
  static String activityAdd({String? url}) => _q('${RootPaths.activity}/add', {'url': url});

  // --- calendar ----------------------------------------------------------------
  static String calendar() => RootPaths.calendar;

  // --- media -------------------------------------------------------------------
  static String media({String? tab}) => _q(RootPaths.media, {'tab': tab});
  static String mediaJellyfin() => '${RootPaths.media}/jellyfin';
  static String mediaAudiobooks() => '${RootPaths.media}/audiobooks';
  static String mediaBooks() => '${RootPaths.media}/books';
  static String mediaShelfmark() => '${RootPaths.media}/shelfmark';
  static String mediaStatsUsers() => '${RootPaths.media}/stats/users';

  // --- containers --------------------------------------------------------------
  static String containers() => RootPaths.containers;
  static String container(String name) => '${RootPaths.containers}/${_seg(name)}';
  static String containerLogs(String name) => '${RootPaths.containers}/${_seg(name)}/logs';
  static String containersUpdates() => '${RootPaths.containers}/updates';
  static String containersMaintenance() => '${RootPaths.containers}/maintenance';

  // --- indexers ----------------------------------------------------------------
  static String indexers() => RootPaths.indexers;
  static String indexer(int id) => '${RootPaths.indexers}/$id';
  static String indexersHistory() => '${RootPaths.indexers}/history';
  static String indexersSearch() => '${RootPaths.indexers}/search';

  // --- subtitles / system ------------------------------------------------------
  static String subtitles({String? tab}) => _q(RootPaths.subtitles, {'tab': tab});
  static String system() => RootPaths.system;

  // --- settings ----------------------------------------------------------------
  static String settings() => RootPaths.settings;
  static String settingsServers() => '${RootPaths.settings}/servers';
  static String settingsServer(String id) => '${RootPaths.settings}/servers/${_seg(id)}';
  static String settingsAccount() => '${RootPaths.settings}/account';
  static String settingsSessions() => '${RootPaths.settings}/sessions';
  static String settingsUsers() => '${RootPaths.settings}/users';
  static String settingsUser(String id) => '${RootPaths.settings}/users/${_seg(id)}';
  static String settingsAudit() => '${RootPaths.settings}/audit';
  static String settingsAppearance() => '${RootPaths.settings}/appearance';
  static String settingsRefresh() => '${RootPaths.settings}/refresh';
  static String settingsApps() => '${RootPaths.settings}/apps';
  static String settingsAbout() => '${RootPaths.settings}/about';

  // --- more --------------------------------------------------------------------
  static String more() => RootPaths.more;
}
