/// The list of feature modules (ARCHITECTURE §5.5). Written once by the core
/// slice; every feature keeps its module class name and constructor.
library;

import '../features/activity/activity_module.dart';
import '../features/calendar/calendar_module.dart';
import '../features/containers/containers_module.dart';
import '../features/indexers/indexers_module.dart';
import '../features/library/library_module.dart';
import '../features/media/media_module.dart';
import '../features/requests/requests_module.dart';
import '../features/subtitles/subtitles_module.dart';
import '../features/system/system_module.dart';
import 'feature_context.dart';

/// Builds every feature module; each gets the shared context with its own
/// `Logger('feature.<id>')`.
List<FeatureModule> buildFeatureModules(FeatureContext ctx) => [
  RequestsModule(ctx.forFeature('requests')),
  LibraryModule(ctx.forFeature('library')),
  ActivityModule(ctx.forFeature('activity')),
  CalendarModule(ctx.forFeature('calendar')),
  IndexersModule(ctx.forFeature('indexers')),
  SubtitlesModule(ctx.forFeature('subtitles')),
  ContainersModule(ctx.forFeature('containers')),
  SystemModule(ctx.forFeature('system')),
  MediaModule(ctx.forFeature('media')),
];
