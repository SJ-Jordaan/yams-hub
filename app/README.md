# YAMS Hub app (`yams_hub`)

Flutter app (Android, iOS, web) for the YAMS Hub gateway. Design: [`docs/ARCHITECTURE.md`](../docs/ARCHITECTURE.md) §7
and [`docs/APP.md`](../docs/APP.md). It talks only to the gateway (`/api/v1` with bearer tokens, or `/yh/api/v1` with
cookies when the web build is served by the gateway).

```sh
source ~/development/env.sh
flutter pub get                                   # never `pub upgrade`; pubspec.lock is committed
flutter analyze && flutter test
flutter build web --release --no-web-resources-cdn
flutter build apk --release
```

## Layout

| Path | What |
|---|---|
| `lib/main.dart` | loads SharedPreferences and the session before `runApp` (auth state is synchronous) |
| `lib/app.dart` | `MaterialApp.router` with `DynamicColorBuilder`, incoming links |
| `lib/core/api/` | `dioProvider`, interceptors (auth → failover → error), `ApiException`, `HubDio` helpers, `CoreApi` |
| `lib/core/auth/` | `TokenManager`, token stores (secure storage / sessionStorage / no-op), `authControllerProvider`, login |
| `lib/core/servers/` | server profiles, `ServerResolver` (happy eyeballs + server proof), `activeServerProvider`, onboarding |
| `lib/core/routing/` | `AppPaths`, router with the 12-branch `StatefulShellRoute`, `ShellScaffold`, More, nav badges, admin guard |
| `lib/core/dashboard/` | Home: alerts panel, `DashboardCardFrame`, card registry |
| `lib/core/launcher/` | web-apps launcher (`/home/apps`, dashboard section, More entry) |
| `lib/core/jobs/` | `jobProvider(id)`, `JobChip` |
| `lib/core/widgets/` | shared widgets (`widgets.dart` exports them all) |
| `lib/features/<feature>/` | feature slices; `<feature>_routes.dart` and `<feature>_dashboard_card.dart` started as core stubs |
| `test/support/` | `FakeApi` (Dio adapter with canned JSON), `pumpHubApp`, model builders |

## Conventions for feature code

- Network: a `data/<feature>_api.dart` class over `ref.watch(dioProvider)` using the `HubDio` helpers
  (`getModel`, `postMap`, ...), which always throw `ApiException`. Long endpoints pass `longOptions()`.
- Navigation across features: `AppPaths.*` only. Admin-only routes use `redirect: adminOnly(parent)`.
- Periodic refresh: call `autoRefresh(ref, RefreshIntervals.x)` at the top of a provider.
- No `dart:io` (use `core/platform/platform.dart`), no `material_ui`, colours from `StatusColors.of(context)`.
- Images: `HubImage(dto.posterPath)`; external web UIs: `openExternal(ref, link)` / `openApp(ref, app)`.

## Web hosting modes

A release web build assumes it is served by the gateway (one implicit profile for the page origin, cookie transport,
no server pages). `flutter run -d chrome` (debug) uses server profiles and bearer tokens kept in `sessionStorage`; a
release build for another origin needs `--dart-define=YAMS_HUB_DEV_WEB=true`.
