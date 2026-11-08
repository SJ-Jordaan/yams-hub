/// Edit and add sheets (APP.md §5.2–5.4).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yams_hub/core/api/api_exception.dart';
import 'package:yams_hub/core/theme/theme.dart';
import 'package:yams_hub/core/widgets/widgets.dart';
import 'package:yams_models/yams_models.dart';

import '../data/library_api.dart';
import '../providers/library_providers.dart';
import 'library_widgets.dart';

Widget _sheetFrame(BuildContext context, {required String title, required List<Widget> children}) => SafeArea(
  child: Padding(
    padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
    child: SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    ),
  ),
);

Widget _profileField<T>({
  required String label,
  required T? value,
  required List<DropdownMenuItem<T>> items,
  required ValueChanged<T?> onChanged,
}) => DropdownButtonFormField<T>(
  initialValue: value,
  isExpanded: true,
  decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
  items: items,
  onChanged: onChanged,
);

List<DropdownMenuItem<int>> _profileItems(List<LibraryQualityProfile> profiles, int? current) => [
  for (final p in profiles) DropdownMenuItem(value: p.id, child: Text(p.name)),
  if (current != null && current > 0 && !profiles.any((p) => p.id == current))
    DropdownMenuItem(value: current, child: Text('Profile $current')),
];

// ---------------------------------------------------------------------------
// Edit series
// ---------------------------------------------------------------------------

/// Monitored, quality profile, series type, monitor new seasons.
class SeriesEditSheet extends ConsumerStatefulWidget {
  const SeriesEditSheet({super.key, required this.series});

  final SeriesSummary series;

  static Future<void> show(BuildContext context, SeriesSummary series) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => SeriesEditSheet(series: series),
  );

  @override
  ConsumerState<SeriesEditSheet> createState() => _SeriesEditSheetState();
}

class _SeriesEditSheetState extends ConsumerState<SeriesEditSheet> {
  late bool _monitored = widget.series.monitored;
  late int _profile = widget.series.qualityProfileId;
  late LibrarySeriesType _type = widget.series.seriesType;
  late bool _newSeasons = widget.series.monitorNewItems != LibraryMonitorNewItems.none;
  bool _saving = false;

  Future<void> _save() async {
    final s = widget.series;
    setState(() => _saving = true);
    try {
      await ref
          .read(seriesDetailProvider(s.id).notifier)
          .edit(
            monitored: _monitored != s.monitored ? _monitored : null,
            qualityProfileId: _profile != s.qualityProfileId ? _profile : null,
            seriesType: _type != s.seriesType ? _type : null,
            monitorNewItems: _newSeasons != (s.monitorNewItems != LibraryMonitorNewItems.none)
                ? (_newSeasons ? LibraryMonitorNewItems.all : LibraryMonitorNewItems.none)
                : null,
          );
      if (mounted) {
        context.showSnack('Saved');
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        context.showError(e);
      }
    }
  }

  bool get _changed {
    final s = widget.series;
    return _monitored != s.monitored ||
        _profile != s.qualityProfileId ||
        _type != s.seriesType ||
        _newSeasons != (s.monitorNewItems != LibraryMonitorNewItems.none);
  }

  @override
  Widget build(BuildContext context) {
    final profiles = ref.watch(libraryProfilesProvider).value?.sonarr.qualityProfiles ?? const [];
    final colors = StatusColors.of(context);
    return _sheetFrame(
      context,
      title: 'Edit ${widget.series.title}',
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Monitored'),
          value: _monitored,
          onChanged: (v) => setState(() => _monitored = v),
        ),
        const SizedBox(height: 8),
        _profileField<int>(
          label: 'Quality profile',
          value: _profile > 0 ? _profile : null,
          items: _profileItems(profiles, widget.series.qualityProfileId),
          onChanged: (v) => setState(() => _profile = v ?? _profile),
        ),
        const SizedBox(height: 16),
        Text('Series type', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 6),
        SegmentedButton<LibrarySeriesType>(
          segments: const [
            ButtonSegment(value: LibrarySeriesType.standard, label: Text('Standard')),
            ButtonSegment(value: LibrarySeriesType.anime, label: Text('Anime')),
            ButtonSegment(value: LibrarySeriesType.daily, label: Text('Daily')),
          ],
          selected: {if (_type != LibrarySeriesType.unknown) _type},
          emptySelectionAllowed: true,
          onSelectionChanged: (s) => setState(() => _type = s.isEmpty ? _type : s.first),
        ),
        if (_type != widget.series.seriesType)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(
              children: [
                Icon(Icons.info_outline, size: 16, color: colors.warning),
                const SizedBox(width: 6),
                const Expanded(child: Text('Changes how future releases are searched and named')),
              ],
            ),
          ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Monitor new seasons'),
          value: _newSeasons,
          onChanged: (v) => setState(() => _newSeasons = v),
        ),
        const SizedBox(height: 8),
        FilledButton(
          onPressed: _saving || !_changed ? null : _save,
          child: _saving
              ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Save'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Edit movie
// ---------------------------------------------------------------------------

const _availabilityChoices = [
  LibraryMinimumAvailability.announced,
  LibraryMinimumAvailability.inCinemas,
  LibraryMinimumAvailability.released,
];

/// Monitored, quality profile, minimum availability.
class MovieEditSheet extends ConsumerStatefulWidget {
  const MovieEditSheet({super.key, required this.movie});

  final MovieSummary movie;

  static Future<void> show(BuildContext context, MovieSummary movie) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => MovieEditSheet(movie: movie),
  );

  @override
  ConsumerState<MovieEditSheet> createState() => _MovieEditSheetState();
}

class _MovieEditSheetState extends ConsumerState<MovieEditSheet> {
  late bool _monitored = widget.movie.monitored;
  late int _profile = widget.movie.qualityProfileId;
  late LibraryMinimumAvailability _availability = widget.movie.minimumAvailability;
  bool _saving = false;

  Future<void> _save() async {
    final m = widget.movie;
    setState(() => _saving = true);
    try {
      await ref
          .read(movieDetailProvider(m.id).notifier)
          .edit(
            monitored: _monitored != m.monitored ? _monitored : null,
            qualityProfileId: _profile != m.qualityProfileId ? _profile : null,
            minimumAvailability: _availability != m.minimumAvailability ? _availability : null,
          );
      if (mounted) {
        context.showSnack('Saved');
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        context.showError(e);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.movie;
    final profiles = ref.watch(libraryProfilesProvider).value?.radarr.qualityProfiles ?? const [];
    final changed =
        _monitored != m.monitored || _profile != m.qualityProfileId || _availability != m.minimumAvailability;
    return _sheetFrame(
      context,
      title: 'Edit ${m.title}',
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Monitored'),
          value: _monitored,
          onChanged: (v) => setState(() => _monitored = v),
        ),
        const SizedBox(height: 8),
        _profileField<int>(
          label: 'Quality profile',
          value: _profile > 0 ? _profile : null,
          items: _profileItems(profiles, m.qualityProfileId),
          onChanged: (v) => setState(() => _profile = v ?? _profile),
        ),
        const SizedBox(height: 16),
        _profileField<LibraryMinimumAvailability>(
          label: 'Minimum availability',
          value: _availabilityChoices.contains(_availability) ? _availability : null,
          items: [
            for (final a in _availabilityChoices) DropdownMenuItem(value: a, child: Text(libraryAvailabilityLabel(a))),
          ],
          onChanged: (v) => setState(() => _availability = v ?? _availability),
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _saving || !changed ? null : _save,
          child: _saving
              ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Save'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Add sheets
// ---------------------------------------------------------------------------

const _seriesMonitorLabels = {
  LibrarySeriesMonitor.all: 'All episodes',
  LibrarySeriesMonitor.future: 'Future episodes',
  LibrarySeriesMonitor.missing: 'Missing episodes',
  LibrarySeriesMonitor.existing: 'Existing episodes',
  LibrarySeriesMonitor.firstSeason: 'First season',
  LibrarySeriesMonitor.latestSeason: 'Latest season',
  LibrarySeriesMonitor.pilot: 'Pilot only',
  LibrarySeriesMonitor.none: 'None',
};

const _movieMonitorLabels = {
  LibraryMovieMonitor.movieOnly: 'Movie only',
  LibraryMovieMonitor.movieAndCollection: 'Movie and collection',
  LibraryMovieMonitor.none: 'None',
};

String _rootLabel(LibraryRootFolder r) => r.freeBytes == null ? r.path : '${r.path} · ${formatBytes(r.freeBytes)} free';

/// Shown when the add failed with `already_exists`; returns the library id.
int? libraryExistingId(Object error) {
  final e = ApiException.from(error);
  if (e.code != ApiErrorCode.alreadyExists) return null;
  final id = e.details?['libraryId'];
  return id is int ? id : -1;
}

/// The add sheet for a Sonarr lookup result. Pops with the library id of
/// the new series (or of the existing one after "Open").
class AddSeriesSheet extends ConsumerStatefulWidget {
  const AddSeriesSheet({super.key, required this.lookup});

  final SeriesLookup lookup;

  static Future<int?> show(BuildContext context, SeriesLookup lookup) => showModalBottomSheet<int>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => AddSeriesSheet(lookup: lookup),
  );

  @override
  ConsumerState<AddSeriesSheet> createState() => _AddSeriesSheetState();
}

class _AddSeriesSheetState extends ConsumerState<AddSeriesSheet> {
  late int? _profile = widget.lookup.suggested.qualityProfileId > 0 ? widget.lookup.suggested.qualityProfileId : null;
  late String? _root = widget.lookup.suggested.rootFolderPath.isEmpty ? null : widget.lookup.suggested.rootFolderPath;
  late LibrarySeriesType _type = widget.lookup.suggested.seriesType == LibrarySeriesType.unknown
      ? LibrarySeriesType.standard
      : widget.lookup.suggested.seriesType;
  LibrarySeriesMonitor _monitor = LibrarySeriesMonitor.all;
  bool _seasonFolder = true;
  bool _searchMissing = true;
  bool _searchCutoff = false;
  bool _saving = false;
  int? _existingId;

  Future<void> _add() async {
    final profile = _profile;
    final root = _root;
    if (profile == null || root == null) return;
    setState(() {
      _saving = true;
      _existingId = null;
    });
    try {
      final added = await ref
          .read(libraryApiProvider)
          .addSeries(
            AddSeriesRequest(
              tvdbId: widget.lookup.tvdbId,
              qualityProfileId: profile,
              rootFolderPath: root,
              seriesType: _type,
              seasonFolder: _seasonFolder,
              monitor: _monitor,
              searchForMissing: _searchMissing,
              searchForCutoffUnmet: _searchCutoff,
            ),
          );
      ref
        ..invalidate(seriesListProvider)
        ..invalidate(librarySummaryProvider);
      if (mounted) Navigator.of(context).pop(added.id);
    } catch (e) {
      if (!mounted) return;
      final existing = libraryExistingId(e);
      setState(() {
        _saving = false;
        _existingId = existing;
      });
      if (existing == null) context.showError(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final profiles = ref.watch(libraryProfilesProvider);
    final p = profiles.value?.sonarr;
    final l = widget.lookup;
    final rootItems = [
      for (final r in p?.rootFolders ?? const <LibraryRootFolder>[])
        DropdownMenuItem(
          value: r.path,
          child: Text(_rootLabel(r), overflow: TextOverflow.ellipsis),
        ),
      if (_root != null && !(p?.rootFolders ?? const []).any((r) => r.path == _root))
        DropdownMenuItem(value: _root, child: Text(_root!)),
    ];
    return _sheetFrame(
      context,
      title: 'Add ${l.title}${l.year == null ? '' : ' (${l.year})'}',
      children: [
        if (profiles.hasError && p == null) ErrorView(error: profiles.error!, compact: true),
        _profileField<int>(
          label: 'Quality profile',
          value: _profile,
          items: _profileItems(p?.qualityProfiles ?? const [], _profile),
          onChanged: (v) => setState(() => _profile = v),
        ),
        const SizedBox(height: 12),
        _profileField<String>(
          label: 'Root folder',
          value: _root,
          items: rootItems,
          onChanged: (v) => setState(() => _root = v),
        ),
        const SizedBox(height: 12),
        Text('Series type', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 6),
        SegmentedButton<LibrarySeriesType>(
          segments: const [
            ButtonSegment(value: LibrarySeriesType.standard, label: Text('Standard')),
            ButtonSegment(value: LibrarySeriesType.anime, label: Text('Anime')),
            ButtonSegment(value: LibrarySeriesType.daily, label: Text('Daily')),
          ],
          selected: {_type},
          onSelectionChanged: (s) => setState(() {
            _type = s.first;
            // Follow the type with the matching default profile.
            final defaults = p?.defaults;
            if (defaults != null) {
              _profile = _type == LibrarySeriesType.anime ? defaults.animeProfileId : defaults.standardProfileId;
            }
          }),
        ),
        if (l.isAnime)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('Anime detected from genres', style: Theme.of(context).textTheme.bodySmall),
          ),
        const SizedBox(height: 12),
        _profileField<LibrarySeriesMonitor>(
          label: 'Monitor',
          value: _monitor,
          items: [for (final e in _seriesMonitorLabels.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
          onChanged: (v) => setState(() => _monitor = v ?? _monitor),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Season folders'),
          value: _seasonFolder,
          onChanged: (v) => setState(() => _seasonFolder = v),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Start searching for missing episodes'),
          value: _searchMissing,
          onChanged: (v) => setState(() => _searchMissing = v),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Also search cutoff unmet'),
          value: _searchCutoff,
          onChanged: (v) => setState(() => _searchCutoff = v),
        ),
        if (_existingId != null) _AlreadyInLibrary(id: _existingId!),
        const SizedBox(height: 8),
        FilledButton(
          onPressed: _saving || _profile == null || _root == null ? null : _add,
          child: _saving
              ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Add'),
        ),
      ],
    );
  }
}

/// The add sheet for a Radarr lookup result. Pops with the library id of
/// the new movie (or of the existing one after "Open").
class AddMovieSheet extends ConsumerStatefulWidget {
  const AddMovieSheet({super.key, required this.lookup});

  final MovieLookup lookup;

  static Future<int?> show(BuildContext context, MovieLookup lookup) => showModalBottomSheet<int>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => AddMovieSheet(lookup: lookup),
  );

  @override
  ConsumerState<AddMovieSheet> createState() => _AddMovieSheetState();
}

class _AddMovieSheetState extends ConsumerState<AddMovieSheet> {
  late int? _profile = widget.lookup.suggested.qualityProfileId > 0 ? widget.lookup.suggested.qualityProfileId : null;
  late String? _root = widget.lookup.suggested.rootFolderPath.isEmpty ? null : widget.lookup.suggested.rootFolderPath;
  LibraryMinimumAvailability _availability = LibraryMinimumAvailability.released;
  LibraryMovieMonitor _monitor = LibraryMovieMonitor.movieOnly;
  bool _search = true;
  bool _saving = false;
  int? _existingId;

  Future<void> _add() async {
    final profile = _profile;
    final root = _root;
    if (profile == null || root == null) return;
    setState(() {
      _saving = true;
      _existingId = null;
    });
    try {
      final added = await ref
          .read(libraryApiProvider)
          .addMovie(
            AddMovieRequest(
              tmdbId: widget.lookup.tmdbId,
              qualityProfileId: profile,
              rootFolderPath: root,
              minimumAvailability: _availability,
              monitor: _monitor,
              searchForMovie: _search,
            ),
          );
      ref
        ..invalidate(moviesListProvider)
        ..invalidate(librarySummaryProvider);
      if (mounted) Navigator.of(context).pop(added.id);
    } catch (e) {
      if (!mounted) return;
      final existing = libraryExistingId(e);
      setState(() {
        _saving = false;
        _existingId = existing;
      });
      if (existing == null) context.showError(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final profiles = ref.watch(libraryProfilesProvider);
    final p = profiles.value?.radarr;
    final l = widget.lookup;
    final rootItems = [
      for (final r in p?.rootFolders ?? const <LibraryRootFolder>[])
        DropdownMenuItem(
          value: r.path,
          child: Text(_rootLabel(r), overflow: TextOverflow.ellipsis),
        ),
      if (_root != null && !(p?.rootFolders ?? const []).any((r) => r.path == _root))
        DropdownMenuItem(value: _root, child: Text(_root!)),
    ];
    return _sheetFrame(
      context,
      title: 'Add ${l.title}${l.year == null ? '' : ' (${l.year})'}',
      children: [
        if (profiles.hasError && p == null) ErrorView(error: profiles.error!, compact: true),
        _profileField<int>(
          label: 'Quality profile',
          value: _profile,
          items: _profileItems(p?.qualityProfiles ?? const [], _profile),
          onChanged: (v) => setState(() => _profile = v),
        ),
        const SizedBox(height: 12),
        _profileField<String>(
          label: 'Root folder',
          value: _root,
          items: rootItems,
          onChanged: (v) => setState(() => _root = v),
        ),
        const SizedBox(height: 12),
        _profileField<LibraryMinimumAvailability>(
          label: 'Minimum availability',
          value: _availability,
          items: [
            for (final a in _availabilityChoices) DropdownMenuItem(value: a, child: Text(libraryAvailabilityLabel(a))),
          ],
          onChanged: (v) => setState(() => _availability = v ?? _availability),
        ),
        const SizedBox(height: 12),
        _profileField<LibraryMovieMonitor>(
          label: 'Monitor',
          value: _monitor,
          items: [for (final e in _movieMonitorLabels.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
          onChanged: (v) => setState(() => _monitor = v ?? _monitor),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Search on add'),
          value: _search,
          onChanged: (v) => setState(() => _search = v),
        ),
        if (_existingId != null) _AlreadyInLibrary(id: _existingId!),
        const SizedBox(height: 8),
        FilledButton(
          onPressed: _saving || _profile == null || _root == null ? null : _add,
          child: _saving
              ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Add'),
        ),
      ],
    );
  }
}

class _AlreadyInLibrary extends StatelessWidget {
  const _AlreadyInLibrary({required this.id});

  /// -1 when the gateway could not tell which item it is.
  final int id;

  @override
  Widget build(BuildContext context) {
    final colors = StatusColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(Icons.info_outline, color: colors.info),
          const SizedBox(width: 8),
          const Expanded(child: Text('Already in your library')),
          if (id > 0) TextButton(onPressed: () => Navigator.of(context).pop(id), child: const Text('Open')),
        ],
      ),
    );
  }
}
