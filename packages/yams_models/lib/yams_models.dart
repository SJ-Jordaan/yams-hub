/// Shared DTOs for the YAMS Hub gateway and app.
///
/// Every source file is re-exported from here, so a public name must be
/// unique across all of them (ARCHITECTURE §4 naming rule). Core files:
/// `json`, `common`, `auth`, `server`, `dashboard`, `arr_common`; every other
/// file belongs to one feature slice.
library;

export 'src/activity.dart';
export 'src/arr_common.dart';
export 'src/auth.dart';
export 'src/calendar.dart';
export 'src/common.dart';
export 'src/containers.dart';
export 'src/dashboard.dart';
export 'src/indexers.dart';
export 'src/json.dart';
export 'src/library.dart';
export 'src/media.dart';
export 'src/requests.dart';
export 'src/server.dart';
export 'src/subtitles.dart';
export 'src/system.dart';
