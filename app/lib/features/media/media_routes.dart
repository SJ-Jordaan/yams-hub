// Routes of the media feature (APP.md §1, §8). One top-level GoRoute at the
// feature root; static sub-routes only (no parameterised ones).

import 'package:go_router/go_router.dart';
import 'package:yams_hub/core/routing/paths.dart';

import 'screens/audiobooks_screen.dart';
import 'screens/books_screen.dart';
import 'screens/jellyfin_screen.dart';
import 'screens/media_screen.dart';
import 'screens/shelfmark_screen.dart';
import 'screens/stats_users_screen.dart';

/// Routes of the media feature (APP.md §1).
final List<RouteBase> mediaRoutes = [
  GoRoute(
    path: RootPaths.media,
    // The parent page is rebuilt for every sub-route and again when a detail
    // screen pops back to a bare `/media`: only an explicit `/media?tab=`
    // selects a tab, so everything else keeps the tab the user was on.
    builder: (context, state) {
      final tab = state.uri.queryParameters['tab'];
      return MediaScreen(initialTab: state.uri.path == RootPaths.media && tab != null ? MediaTab.parse(tab) : null);
    },
    routes: [
      GoRoute(path: 'jellyfin', builder: (context, state) => const JellyfinScreen()),
      GoRoute(path: 'audiobooks', builder: (context, state) => const AudiobooksScreen()),
      GoRoute(path: 'books', builder: (context, state) => const BooksScreen()),
      GoRoute(path: 'shelfmark', builder: (context, state) => const ShelfmarkScreen()),
      GoRoute(path: 'stats/users', builder: (context, state) => const StatsUsersScreen()),
    ],
  ),
];
