/// Title detail `/requests/title/:mediaType/:tmdbId` (APP.md §4.3).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:yams_hub/core/api/api_exception.dart';
import 'package:yams_hub/core/auth/auth_controller.dart';
import 'package:yams_hub/core/links/external_links.dart';
import 'package:yams_hub/core/routing/paths.dart';
import 'package:yams_hub/core/theme/theme.dart';
import 'package:yams_hub/core/widgets/widgets.dart';
import 'package:yams_models/yams_models.dart';

import '../data/requests_api.dart';
import '../providers/requests_providers.dart';
import '../widgets/report_issue_sheet.dart';
import '../widgets/request_sheet.dart';
import '../widgets/request_ui.dart';
import '../widgets/title_widgets.dart';

class TitleScreen extends ConsumerWidget {
  const TitleScreen({super.key, required this.mediaType, required this.tmdbId});

  final MediaType mediaType;
  final int tmdbId;

  TitleKey get _key => (type: mediaType, tmdbId: tmdbId);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(titleDetailProvider(_key));
    final detail = value.value;
    if (detail != null) {
      return _TitleView(detail: detail, stale: value.hasError, refreshKey: _key);
    }
    if (value.hasError) {
      final e = ApiException.from(value.error!);
      return Scaffold(
        appBar: AppBar(),
        body: e.status == 404
            ? EmptyView(
                icon: Icons.search_off,
                title: "This title doesn't exist on TMDB",
                action: OutlinedButton(onPressed: () => context.go(AppPaths.requests()), child: const Text('Discover')),
              )
            : ErrorView(error: e, onRetry: () => ref.invalidate(titleDetailProvider(_key))),
      );
    }
    return Scaffold(appBar: AppBar(), body: const _TitleSkeleton());
  }
}

class _TitleSkeleton extends StatelessWidget {
  const _TitleSkeleton();

  @override
  Widget build(BuildContext context) => ListView(
    physics: const NeverScrollableScrollPhysics(),
    children: const [
      AspectRatio(aspectRatio: 16 / 9, child: SkeletonBox(radius: 0)),
      Padding(
        padding: EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 100, height: 150, child: SkeletonBox(radius: 12)),
            SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SkeletonBox(height: 24),
                  SizedBox(height: 12),
                  SkeletonBox(width: 160),
                  SizedBox(height: 12),
                  SkeletonBox(width: 120),
                ],
              ),
            ),
          ],
        ),
      ),
      Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: SkeletonBox(height: 40, radius: 20)),
      SizedBox(height: 24),
      Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: SkeletonBox(height: 80)),
    ],
  );
}

class _TitleView extends ConsumerStatefulWidget {
  const _TitleView({required this.detail, required this.stale, required this.refreshKey});

  final TitleDetail detail;
  final bool stale;
  final TitleKey refreshKey;

  @override
  ConsumerState<_TitleView> createState() => _TitleViewState();
}

class _TitleViewState extends ConsumerState<_TitleView> {
  bool _busy = false;

  TitleDetail get t => widget.detail;

  void _snack(String text) => ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));

  Future<void> _refresh() async {
    ref
      ..invalidate(titleDetailProvider(widget.refreshKey))
      ..invalidate(titleRatingsProvider(widget.refreshKey));
    try {
      await ref.read(titleDetailProvider(widget.refreshKey).future);
    } catch (_) {
      // The stale banner says so.
    }
  }

  Future<void> _request({bool withOptions = false}) async {
    final CreateRequest? request = t.isTv || withOptions
        ? await showRequestSheet(context, t)
        : CreateRequest(mediaType: MediaType.movie, tmdbId: t.tmdbId);
    if (request == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final result = await ref.read(requestsApiProvider).create(request);
      if (!mounted) return;
      _snack(requestResultMessage(result, type: t.type, isAdmin: ref.read(isAdminProvider)));
      ref
        ..invalidate(meProvider)
        ..read(requestsGenerationProvider.notifier).bump();
    } catch (e) {
      if (!mounted) return;
      _snack(requestErrorMessage(e, t.type));
      final code = ApiException.from(e).code;
      if (code == ApiErrorCode.quotaExceeded) ref.invalidate(meProvider);
      if (code == ApiErrorCode.alreadyRequested || code == ClientErrorCode.resultUnknown) {
        ref.read(requestsGenerationProvider.notifier).bump();
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openJellyfin(ExternalLink link) async {
    if (!await openExternal(ref, link) && mounted) _snack("Couldn't open Jellyfin");
  }

  Future<void> _reportIssue() async {
    await showReportIssueSheet(context, t);
  }

  void _openLibrary(int id) => context.go(t.isTv ? AppPaths.seriesDetail(id) : AppPaths.movieDetail(id));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final width = MediaQuery.sizeOf(context).width;
    final backdropHeight = (width * 9 / 16).clamp(160.0, 320.0);
    return Scaffold(
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: CustomScrollView(
          slivers: [
            SliverAppBar(
              pinned: true,
              expandedHeight: backdropHeight,
              title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis),
              flexibleSpace: FlexibleSpaceBar(
                collapseMode: CollapseMode.parallax,
                background: Stack(
                  fit: StackFit.expand,
                  children: [
                    HubImage(t.backdropPath, placeholderIcon: mediaTypeIcon(t.type)),
                    DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Colors.black.withValues(alpha: 0.45), Colors.transparent, theme.colorScheme.surface],
                          stops: const [0, 0.45, 1],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (widget.stale) SliverToBoxAdapter(child: StaleBanner(onRetry: _refresh)),
            SliverToBoxAdapter(
              child: _Header(detail: t, ratingsKey: widget.refreshKey),
            ),
            SliverToBoxAdapter(child: _actions(context)),
            SliverList.list(children: _body(context)),
            SliverToBoxAdapter(
              child: TitleCarousel(
                title: 'Recommended',
                provider: relatedTitlesProvider((key: widget.refreshKey, similar: false)),
                hideWhenEmpty: true,
              ),
            ),
            SliverToBoxAdapter(
              child: TitleCarousel(
                title: 'Similar',
                provider: relatedTitlesProvider((key: widget.refreshKey, similar: true)),
                hideWhenEmpty: true,
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 32)),
          ],
        ),
      ),
    );
  }

  Widget _actions(BuildContext context) {
    final theme = Theme.of(context);
    final colors = StatusColors.of(context);
    final isAdmin = ref.watch(isAdminProvider);
    final seerr = ref.watch(seerrInfoProvider);
    final media = t.media;
    final e = t.request;
    final a = t.availability;
    final quota = quotaFor(seerr, t.type);
    final quotaText = isAdmin ? null : quotaLine(quota, t.type);
    final blocked = !isAdmin && quotaBlocks(quota);
    final jellyfin = media?.jellyfin;
    final playable = jellyfin != null && (a == Availability.available || a == Availability.partial);
    final canReport = media != null && (isAdmin || (seerr?.linked ?? false));
    final spinner = const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2));

    Widget? primary;
    String? note;
    if (e.canRequest) {
      final label = blocked ? 'No requests left' : (a == Availability.partial ? 'Request more' : 'Request');
      primary = FilledButton.icon(
        onPressed: _busy || blocked ? null : _request,
        icon: _busy ? spinner : const Icon(Icons.add),
        label: Text(label),
      );
    } else if (e.reason == RequestEligibilityReason.notLinked) {
      primary = FilledButton.icon(onPressed: null, icon: const Icon(Icons.add), label: const Text('Request'));
      note = "Your account isn't linked to Seerr. Ask the admin.";
    } else if (e.reason == RequestEligibilityReason.blocklisted) {
      primary = FilledButton.icon(onPressed: null, icon: const Icon(Icons.block), label: const Text('Blocklisted'));
    } else if (a == Availability.pending ||
        a == Availability.processing ||
        e.reason == RequestEligibilityReason.alreadyRequested) {
      primary = FilledButton.tonalIcon(
        onPressed: null,
        icon: Icon(a == Availability.pending ? Icons.hourglass_top : Icons.schedule),
        label: Text(a == Availability.pending ? 'Requested · waiting for approval' : 'Requested'),
      );
    }

    final buttons = <Widget>[
      ?primary,
      if (playable)
        primary == null
            ? FilledButton.icon(
                onPressed: () => _openJellyfin(jellyfin),
                icon: const Icon(Icons.play_arrow),
                label: const Text('Play in Jellyfin'),
              )
            : OutlinedButton.icon(
                onPressed: () => _openJellyfin(jellyfin),
                icon: const Icon(Icons.play_arrow),
                label: const Text('Play in Jellyfin'),
              ),
      if (isAdmin && e.canRequest && !t.isTv)
        IconButton.outlined(
          tooltip: 'Request with options',
          onPressed: _busy ? null : () => _request(withOptions: true),
          icon: const Icon(Icons.tune),
        ),
      if (canReport)
        TextButton.icon(
          onPressed: _reportIssue,
          icon: const Icon(Icons.flag_outlined),
          label: const Text('Report issue'),
        ),
      if (media?.libraryId case final id?)
        TextButton.icon(
          onPressed: () => _openLibrary(id),
          icon: const Icon(Icons.video_library_outlined),
          label: const Text('Open in Library'),
        ),
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: buttons),
          if (note != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(note, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ),
          if (quotaText != null && e.canRequest)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                quotaText,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: blocked ? colors.error : theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          for (final d in media?.downloads ?? const <RequestDownloadProgress>[])
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: ProgressBar(
                value: d.progress,
                label: d.title,
                trailing: [
                  formatPercent(d.progress * 100),
                  if (d.etaSeconds != null) formatEta(d.etaSeconds),
                ].join(' · '),
              ),
            ),
        ],
      ),
    );
  }

  List<Widget> _body(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final media = t.media;
    final tv = t.tv;
    return [
      if (t.tagline != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Text(t.tagline!, style: theme.textTheme.titleSmall?.copyWith(fontStyle: FontStyle.italic)),
        ),
      if (t.overview != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Text(t.overview!, style: theme.textTheme.bodyMedium),
        ),
      if (t.trailer case final trailer?)
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 16, 0),
          child: Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => launchExternalUri(trailer.url),
              icon: const Icon(Icons.smart_display_outlined),
              label: Text(
                trailer.name == null ? 'Watch trailer' : 'Trailer · ${trailer.name}',
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ),
      _Facts(detail: t),
      if (t.cast.isNotEmpty) ...[
        const _SectionTitle('Cast'),
        SizedBox(
          height: 150,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: t.cast.length,
            separatorBuilder: (_, _) => const SizedBox(width: 12),
            itemBuilder: (context, i) => _CastTile(member: t.cast[i]),
          ),
        ),
      ],
      if (tv != null && tv.seasons.isNotEmpty) ...[
        const _SectionTitle('Seasons'),
        for (final s in tv.seasons)
          ListTile(
            dense: true,
            title: Text(s.name),
            subtitle: Text(
              [
                '${s.episodeCount} episodes',
                if (s.airDate != null && s.airDate!.length >= 4) s.airDate!.substring(0, 4),
              ].join(' · '),
            ),
            trailing: s.availability == Availability.none && s.requestStatus != null
                ? StatusChip(
                    label: requestStatusLabel(s.requestStatus!),
                    tone: requestStatusTone(s.requestStatus!),
                    dense: true,
                  )
                : StatusChip(
                    label: availabilityLabel(s.availability),
                    tone: availabilityTone(s.availability),
                    dense: true,
                  ),
          ),
      ],
      if (t.watchProviders.isNotEmpty) ...[
        const _SectionTitle('Where to watch (ZA)'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final p in t.watchProviders)
                Chip(
                  avatar: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: HubImage(p.logoPath, width: 24, height: 24, placeholderIcon: Icons.live_tv),
                  ),
                  label: Text(
                    '${p.name}${switch (p.type) {
                      RequestsWatchProviderType.rent => ' · rent',
                      RequestsWatchProviderType.buy => ' · buy',
                      _ => '',
                    }}',
                  ),
                ),
            ],
          ),
        ),
      ],
      if (t.movie?.collection case final c?)
        ListTile(
          leading: const Icon(Icons.collections_bookmark_outlined),
          title: Text(c.name),
          subtitle: const Text('Part of a collection'),
        ),
      if (media != null && media.requests.isNotEmpty) ...[
        const _SectionTitle('Requests'),
        for (final r in media.requests)
          ListTile(
            leading: SeerrAvatar(name: r.requestedBy.displayName, path: r.requestedBy.avatarPath, size: 32),
            title: Text(r.requestedBy.displayName),
            subtitle: Text(
              [
                if (r.seasons.isNotEmpty) seasonsLabel([for (final s in r.seasons) s.seasonNumber]),
                formatRelative(r.createdAt),
              ].join(' · '),
              style: muted,
            ),
            trailing: RequestStatusChip(request: r),
            onTap: () => context.push(AppPaths.requestDetail(r.id)),
          ),
      ],
      if (media != null && media.openIssues > 0)
        ListTile(
          leading: Icon(Icons.report_problem_outlined, color: StatusColors.of(context).warning),
          title: Text('${media.openIssues} open issue${media.openIssues == 1 ? '' : 's'}'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.push(AppPaths.issues()),
        ),
    ];
  }
}

class _Header extends ConsumerWidget {
  const _Header({required this.detail, required this.ratingsKey});

  final TitleDetail detail;
  final TitleKey ratingsKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final t = detail;
    final runtime = t.runtimeMinutes;
    final meta = [
      ?t.year?.toString(),
      if (runtime != null) t.isTv ? '${formatRuntime(runtime)} / ep' : formatRuntime(runtime),
      ?t.certification,
      if (t.isTv) mediaTypeLabel(t.type),
    ].join(' · ');
    final ratings = ref.watch(titleRatingsProvider(ratingsKey)).value;
    final scores = [
      if (t.voteAverage case final v? when v > 0) 'TMDB ${v.toStringAsFixed(1)}',
      if (ratings?.rottenTomatoes?.criticsScore case final c?) 'RT $c%',
      if (ratings?.rottenTomatoes?.audienceScore case final a?) 'Audience $a%',
      if (ratings?.imdb?.score case final s?) 'IMDb ${s.toStringAsFixed(1)}',
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: AspectRatio(
              aspectRatio: 2 / 3,
              child: HubImage(
                t.posterPath,
                borderRadius: BorderRadius.circular(12),
                placeholderIcon: mediaTypeIcon(t.type),
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(t.title, style: theme.textTheme.headlineSmall),
                if (meta.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(meta, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                ],
                const SizedBox(height: 8),
                StatusChip(
                  label: availabilityLabel(t.availability),
                  tone: availabilityTone(t.availability),
                  dense: true,
                ),
                if (scores.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(scores.join(' · '), style: theme.textTheme.labelLarge),
                ],
                if (t.genres.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final g in t.genres)
                        Chip(
                          label: Text(g),
                          visualDensity: VisualDensity.compact,
                          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// "1 h 34 min".
String formatRuntime(int minutes) {
  if (minutes < 60) return '$minutes min';
  final h = minutes ~/ 60;
  final m = minutes % 60;
  return m == 0 ? '$h h' : '$h h $m min';
}

class _Facts extends StatelessWidget {
  const _Facts({required this.detail});

  final TitleDetail detail;

  @override
  Widget build(BuildContext context) {
    final t = detail;
    final tv = t.tv;
    final next = tv?.nextEpisode;
    final entries = [
      if (t.people.isNotEmpty) KeyValue(t.isTv ? 'Created by' : 'Directed by', t.people.join(', ')),
      if (tv != null) ...[
        if (tv.networks.isNotEmpty) KeyValue('Network', tv.networks.join(', ')),
        if (tv.status.isNotEmpty) KeyValue('Status', tv.status),
        KeyValue('Seasons', '${tv.numberOfSeasons} · ${tv.numberOfEpisodes} episodes'),
        if (tv.firstAirDate != null) KeyValue('First aired', formatCalendarDate(tv.firstAirDate)),
        if (next != null)
          KeyValue(
            'Next episode',
            [
              'S${next.seasonNumber}E${next.episodeNumber}',
              ?next.name,
              if (next.airDate != null) formatCalendarDate(next.airDate),
            ].join(' · '),
          ),
      ],
      if (t.movie?.releaseDate case final d?) KeyValue('Released', formatCalendarDate(d)),
    ];
    if (entries.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: KeyValueList(entries: entries, labelWidth: 110),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
    child: Text(text, style: Theme.of(context).textTheme.titleMedium),
  );
}

class _CastTile extends StatelessWidget {
  const _CastTile({required this.member});

  final RequestsCastMember member;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: 84,
      child: Column(
        children: [
          ClipOval(child: HubImage(member.profilePath, width: 72, height: 72, placeholderIcon: Icons.person_outline)),
          const SizedBox(height: 6),
          Text(
            member.name,
            maxLines: 2,
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall,
          ),
          if (member.character != null)
            Text(
              member.character!,
              maxLines: 1,
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
        ],
      ),
    );
  }
}
