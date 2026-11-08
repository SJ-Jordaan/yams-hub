// Routes of the requests feature (APP.md §1, §4). Static sub-routes come
// before parameterised ones; none of these routes is admin-only (members see
// "Mine" in the list and admin actions are hidden).

import 'package:go_router/go_router.dart';
import 'package:yams_hub/core/routing/not_found_screen.dart';
import 'package:yams_hub/core/routing/paths.dart';
import 'package:yams_models/yams_models.dart';

import 'data/requests_api.dart';
import 'screens/discover_screens.dart';
import 'screens/issues_screens.dart';
import 'screens/requests_screens.dart';
import 'screens/title_screen.dart';

/// Routes of the requests feature (APP.md §1).
final List<RouteBase> requestsRoutes = [
  GoRoute(
    path: RootPaths.requests,
    builder: (context, state) => const DiscoverScreen(),
    routes: [
      GoRoute(
        path: 'search',
        builder: (context, state) => SearchScreen(query: state.uri.queryParameters['q'] ?? ''),
      ),
      GoRoute(
        path: 'list',
        builder: (context, state) => RequestsListScreen(tab: state.uri.queryParameters['tab']),
        routes: [
          GoRoute(
            path: ':id',
            builder: (context, state) => switch (int.tryParse(state.pathParameters['id']!)) {
              final id? => RequestDetailScreen(id: id),
              null => NotFoundScreen(location: state.uri.toString()),
            },
          ),
        ],
      ),
      GoRoute(
        path: 'issues',
        builder: (context, state) => const IssuesScreen(),
        routes: [
          GoRoute(
            path: ':id',
            builder: (context, state) => switch (int.tryParse(state.pathParameters['id']!)) {
              final id? => IssueDetailScreen(id: id),
              null => NotFoundScreen(location: state.uri.toString()),
            },
          ),
        ],
      ),
      GoRoute(
        path: 'discover/:slider',
        builder: (context, state) => switch (DiscoverSlider.fromSlug(state.pathParameters['slider']!)) {
          final slider? => DiscoverGridScreen(
            slider: slider,
            mediaType: switch (state.uri.queryParameters['mediaType']) {
              'movie' => MediaType.movie,
              'tv' => MediaType.tv,
              _ => null,
            },
          ),
          null => NotFoundScreen(location: state.uri.toString()),
        },
      ),
      GoRoute(
        path: 'title/:mediaType/:tmdbId',
        builder: (context, state) {
          final type = switch (state.pathParameters['mediaType']) {
            'movie' => MediaType.movie,
            'tv' => MediaType.tv,
            _ => null,
          };
          final id = int.tryParse(state.pathParameters['tmdbId']!);
          if (type == null || id == null) return NotFoundScreen(location: state.uri.toString());
          return TitleScreen(mediaType: type, tmdbId: id);
        },
      ),
    ],
  ),
];
