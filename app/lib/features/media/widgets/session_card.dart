/// A Jellyfin session: the full card of the Now playing tab and the compact
/// row of the dashboard card.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yams_hub/core/api/api_client.dart';
import 'package:yams_hub/core/widgets/widgets.dart';
import 'package:yams_models/yams_models.dart';

import '../providers/media_providers.dart';
import 'media_common.dart';

/// "Desperate Housewives" for episodes, the title otherwise.
String sessionHeadline(NowPlayingSession s) =>
    s.itemType == NowPlayingItemType.episode && s.seriesName != null ? s.seriesName! : s.title;

/// "S05E18 · A Spark…" for episodes, the year for movies, the artist line otherwise.
String? sessionSubline(NowPlayingSession s) {
  if (s.itemType == NowPlayingItemType.episode) {
    final code = s.episodeCode;
    if (s.seriesName == null) return code;
    return [?code, s.title].join(' · ');
  }
  return s.year?.toString();
}

/// "Ada · Living room TV".
String sessionWho(NowPlayingSession s) =>
    [if (s.userName.isNotEmpty) s.userName, if (s.deviceName.isNotEmpty) s.deviceName].join(' · ');

/// The hardware acceleration shown on the play-method chip.
String? sessionHwAccel(NowPlayingSession s, String? serverHwAccel) =>
    s.transcode?.hwAccel ?? (s.isTranscoding ? serverHwAccel : null);

/// The full session card (APP.md §8.1).
class SessionCard extends ConsumerStatefulWidget {
  const SessionCard({super.key, required this.session, this.serverHwAccel});

  final NowPlayingSession session;
  final String? serverHwAccel;

  @override
  ConsumerState<SessionCard> createState() => _SessionCardState();
}

class _SessionCardState extends ConsumerState<SessionCard> {
  String? _busy;

  NowPlayingSession get s => widget.session;

  Future<void> _run(String action, Future<void> Function() call, {String? done}) async {
    setState(() => _busy = action);
    try {
      await call();
      if (mounted && done != null) context.showSnack(done);
    } catch (e) {
      if (mounted) context.showError(ApiException.from(e));
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _togglePause() {
    final cmd = s.paused ? MediaPlaybackCommand.unpause : MediaPlaybackCommand.pause;
    return _run('pause', () => ref.read(sessionActionsProvider).playback(s.id, cmd));
  }

  Future<void> _stop() async {
    final who = s.userName.isEmpty ? 'this session' : s.userName;
    final where = s.deviceName.isEmpty ? '' : ' on ${s.deviceName}';
    final ok = await ConfirmDialog.show(
      context,
      title: 'Stop playback?',
      message: 'Stop playback for $who$where?',
      confirmLabel: 'Stop',
      destructive: true,
    );
    if (!ok || !mounted) return;
    await _run(
      'stop',
      () => ref.read(sessionActionsProvider).playback(s.id, MediaPlaybackCommand.stop),
      done: 'Playback stopped',
    );
  }

  Future<void> _message() async {
    final message = await showDialog<MediaSessionMessage>(
      context: context,
      builder: (_) => SendMessageDialog(target: sessionWho(s)),
    );
    if (message == null || !mounted) return;
    await _run('message', () => ref.read(sessionActionsProvider).message(s.id, message), done: 'Message sent');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final sub = sessionSubline(s);
    final runtime = s.runtimeSeconds;
    final transcode = s.transcode;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (s.backdropPath != null)
            AspectRatio(
              aspectRatio: 16 / 7,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // Sized so native decodes at the displayed size.
                  LayoutBuilder(
                    builder: (context, c) => HubImage(
                      s.backdropPath,
                      width: c.maxWidth,
                      height: c.maxHeight,
                      placeholderIcon: Icons.live_tv,
                    ),
                  ),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.transparent, scheme.surfaceContainerLow],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 72,
                  height: 108,
                  child: HubImage(
                    s.imagePath,
                    width: 72,
                    height: 108,
                    borderRadius: BorderRadius.circular(8),
                    placeholderIcon: s.itemType == NowPlayingItemType.audio ? Icons.music_note : Icons.movie_outlined,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      InkWell(
                        onTap: s.jellyfin == null ? null : () => openLink(context, ref, s.jellyfin, name: 'Jellyfin'),
                        child: Row(
                          children: [
                            Flexible(
                              child: Text(
                                sessionHeadline(s),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.titleMedium,
                              ),
                            ),
                            if (s.jellyfin != null) ...[
                              const SizedBox(width: 4),
                              Icon(Icons.open_in_new, size: 14, color: scheme.onSurfaceVariant),
                            ],
                          ],
                        ),
                      ),
                      if (sub != null && sub.isNotEmpty)
                        Text(
                          sub,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          CircleAvatar(
                            radius: 11,
                            backgroundColor: scheme.secondaryContainer,
                            child: ClipOval(
                              child: s.userImagePath == null
                                  ? Icon(Icons.person, size: 14, color: scheme.onSecondaryContainer)
                                  : HubImage(s.userImagePath, width: 22, height: 22, placeholderIcon: Icons.person),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              s.userName.isEmpty ? 'Unknown user' : s.userName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyMedium,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        [
                          if (s.client.isNotEmpty) s.client,
                          if (s.deviceName.isNotEmpty) s.deviceName,
                          ?s.remoteAddress,
                        ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: ProgressBar(
              value: s.progress,
              label: s.paused ? 'Paused' : null,
              trailing: runtime == null
                  ? formatClock(s.positionSeconds)
                  : '${formatClock(s.positionSeconds)} / ${formatClock(runtime)}',
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                PlayMethodChip(method: s.playMethod, hwAccel: sessionHwAccel(s, widget.serverHwAccel), dense: false),
                if (s.paused) const StatusChip(label: 'Paused', icon: Icons.pause),
              ],
            ),
          ),
          if (transcode != null)
            _TranscodeDetails(transcode: transcode, hwAccel: sessionHwAccel(s, widget.serverHwAccel)),
          if (s.canControl)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
              child: Wrap(
                spacing: 4,
                children: [
                  _ActionButton(
                    icon: s.paused ? Icons.play_arrow : Icons.pause,
                    label: s.paused ? 'Resume' : 'Pause',
                    busy: _busy == 'pause',
                    onPressed: _busy == null ? _togglePause : null,
                  ),
                  _ActionButton(
                    icon: Icons.stop,
                    label: 'Stop',
                    busy: _busy == 'stop',
                    onPressed: _busy == null ? _stop : null,
                  ),
                  _ActionButton(
                    icon: Icons.message_outlined,
                    label: 'Message',
                    busy: _busy == 'message',
                    onPressed: _busy == null ? _message : null,
                  ),
                ],
              ),
            )
          else
            const SizedBox(height: 12),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({required this.icon, required this.label, required this.busy, this.onPressed});

  final IconData icon;
  final String label;
  final bool busy;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: onPressed,
      icon: busy ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)) : Icon(icon),
      label: Text(label),
    );
  }
}

class _TranscodeDetails extends StatelessWidget {
  const _TranscodeDetails({required this.transcode, this.hwAccel});

  final NowPlayingTranscode transcode;
  final String? hwAccel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = transcode;
    String stream(bool? direct, String? codec) {
      if (direct == true) return 'Direct${codec == null ? '' : ' ($codec)'}';
      return codec == null ? 'Converting' : '→ $codec';
    }

    final bitrate = t.bitrate;
    return Theme(
      data: theme.copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        dense: true,
        tilePadding: const EdgeInsets.symmetric(horizontal: 12),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        title: Text('Transcoding details', style: theme.textTheme.labelLarge),
        children: [
          KeyValueList(
            dense: true,
            labelWidth: 96,
            entries: [
              KeyValue('Video', stream(t.videoDirect, t.videoCodec)),
              KeyValue('Audio', stream(t.audioDirect, t.audioCodec)),
              KeyValue('Container', t.container),
              KeyValue('HW', hwAccel == null ? 'Software' : hwAccel!.toUpperCase()),
              if (bitrate != null) KeyValue('Bitrate', '${(bitrate / 1e6).toStringAsFixed(1)} Mbps'),
              if (t.width != null && t.height != null) KeyValue('Resolution', '${t.width}×${t.height}'),
              if (t.completionPercent != null) KeyValue('Transcoded', formatPercent(t.completionPercent)),
            ],
          ),
          if (t.reasons.isNotEmpty) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [for (final r in t.reasons) StatusChip(label: _reasonLabel(r), dense: true)],
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// `VideoCodecNotSupported` → `Video codec not supported`.
  static String _reasonLabel(String raw) {
    final words = raw.replaceAllMapped(RegExp(r'(?<=[a-z])(?=[A-Z])'), (_) => ' ').toLowerCase();
    return words.isEmpty ? raw : '${words[0].toUpperCase()}${words.substring(1)}';
  }
}

/// "Send message" dialog: returns the message, or null when cancelled.
class SendMessageDialog extends StatefulWidget {
  const SendMessageDialog({super.key, required this.target});

  final String target;

  @override
  State<SendMessageDialog> createState() => _SendMessageDialogState();
}

class _SendMessageDialogState extends State<SendMessageDialog> {
  final _text = TextEditingController();
  final _header = TextEditingController(text: 'YAMS Hub');

  @override
  void initState() {
    super.initState();
    _text.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _text.dispose();
    _header.dispose();
    super.dispose();
  }

  bool get _valid => _text.text.trim().isNotEmpty && _text.text.trim().length <= 200;

  void _send() {
    if (!_valid) return;
    final header = _header.text.trim();
    Navigator.of(context).pop(MediaSessionMessage(text: _text.text.trim(), header: header.isEmpty ? null : header));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Send message'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.target.isNotEmpty)
              Padding(padding: const EdgeInsets.only(bottom: 12), child: Text('Shown on ${widget.target}')),
            TextField(
              controller: _header,
              maxLength: 100,
              decoration: const InputDecoration(labelText: 'Title'),
            ),
            TextField(
              key: const Key('media.message.text'),
              controller: _text,
              autofocus: true,
              maxLength: 200,
              minLines: 2,
              maxLines: 4,
              decoration: const InputDecoration(labelText: 'Message', hintText: 'Server restarting in 5 min'),
              onSubmitted: (_) => _send(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(onPressed: _valid ? _send : null, child: const Text('Send')),
      ],
    );
  }
}

/// The compact session row of the dashboard card.
class SessionRow extends StatelessWidget {
  const SessionRow({super.key, required this.session, this.serverHwAccel, this.onTap});

  final NowPlayingSession session;
  final String? serverHwAccel;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = session;
    final sub = sessionSubline(s);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            HubImage(
              s.imagePath,
              width: 40,
              height: 60,
              borderRadius: BorderRadius.circular(6),
              placeholderIcon: s.itemType == NowPlayingItemType.audio ? Icons.music_note : Icons.movie_outlined,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          [sessionHeadline(s), if (s.episodeCode != null) s.episodeCode!].join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall,
                        ),
                      ),
                      if (s.paused)
                        Padding(
                          padding: const EdgeInsets.only(left: 4),
                          child: Icon(
                            Icons.pause_circle_outline,
                            size: 16,
                            color: theme.colorScheme.onSurfaceVariant,
                            semanticLabel: 'Paused',
                          ),
                        ),
                    ],
                  ),
                  Text(
                    sessionWho(s).isEmpty ? (sub ?? '') : sessionWho(s),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Expanded(child: ProgressBar(value: s.progress, height: 4)),
                      const SizedBox(width: 8),
                      PlayMethodChip(method: s.playMethod, hwAccel: sessionHwAccel(s, serverHwAccel)),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
