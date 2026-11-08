import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yams_hub/core/api/api_client.dart';
import 'package:yams_hub/core/jobs/job_provider.dart';
import 'package:yams_hub/core/theme/theme.dart';
import 'package:yams_hub/core/widgets/widgets.dart';
import 'package:yams_models/yams_models.dart';

import '../support/builders.dart';

Widget wrap(Widget child, {List<dynamic> overrides = const []}) => ProviderScope(
  retry: (_, _) => null,
  overrides: [...overrides.cast()],
  child: MaterialApp(theme: buildHubTheme(seededScheme(const Color(0xFF7C4DFF), Brightness.dark)), home: Scaffold(body: child)),
);

void main() {
  testWidgets('JobChip polls until the job finishes, then reports once', (tester) async {
    var polls = 0;
    final done = <Job>[];
    await tester.pumpWidget(
      wrap(
        JobChip('j_1', onDone: done.add),
        overrides: [
          jobProvider.overrideWith((ref, id) async {
            polls++;
            final job = buildJob(id: id, status: polls < 3 ? JobStatus.running : JobStatus.succeeded);
            if (!job.status.isFinished) {
              Future.delayed(jobPollInterval, () {
                if (ref.mounted) ref.invalidateSelf();
              });
            }
            return job;
          }),
        ],
      ),
    );
    await tester.pump();
    expect(find.text('Restart sonarr'), findsOneWidget);
    await tester.pump(jobPollInterval);
    await tester.pump();
    await tester.pump(jobPollInterval);
    await tester.pump();
    expect(polls, 3);
    expect(done.single.status, JobStatus.succeeded);
    expect(find.text('Restart sonarr: done'), findsWidgets);
    await tester.pump(const Duration(seconds: 5));
    expect(done, hasLength(1));
  });

  test('JobChip labels', () {
    final failed = buildJob(
      status: JobStatus.failed,
      error: const ApiError(code: ApiErrorCode.upstreamError, message: 'Docker said no', status: 502),
    );
    expect(JobChip.resultFor(failed), 'Restart sonarr: Docker said no');
  });

  testWidgets('ConfirmDialog returns true only on confirm', (tester) async {
    bool? result;
    await tester.pumpWidget(
      wrap(
        Builder(
          builder: (context) => TextButton(
            onPressed: () async => result = await ConfirmDialog.show(
              context,
              title: 'Stop gluetun?',
              message: 'qBittorrent will lose network until gluetun is back',
              confirmLabel: 'Stop',
              destructive: true,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(result, isFalse);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Stop'));
    await tester.pumpAndSettle();
    expect(result, isTrue);
  });

  testWidgets('TypedConfirmDialog enables confirm only for the exact title', (tester) async {
    bool? result;
    await tester.pumpWidget(
      wrap(
        Builder(
          builder: (context) => TextButton(
            onPressed: () async => result = await TypedConfirmDialog.show(context, expected: 'The Expanse'),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    FilledButton delete() => tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Delete'));
    expect(delete().onPressed, isNull);
    await tester.enterText(find.byType(TextField), 'The Expans');
    await tester.pump();
    expect(delete().onPressed, isNull);
    await tester.enterText(find.byType(TextField), 'The Expanse');
    await tester.pump();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(result, isTrue);
  });

  testWidgets('InfiniteList pages through a PagedList and shows the empty view', (tester) async {
    final pages = <int>[];
    await tester.pumpWidget(
      wrap(
        InfiniteList.paged<int>(
          fetchPage: (page) async {
            pages.add(page);
            return PagedList.of(
              items: [for (var i = 0; i < 25; i++) (page - 1) * 25 + i],
              page: page,
              pageSize: 25,
              total: 40,
            );
          },
          itemBuilder: (context, item, index) => SizedBox(height: 40, child: Text('item $item')),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('item 0'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('item 39'), 400);
    expect(pages, [1, 2]);

    await tester.pumpWidget(
      wrap(
        InfiniteList.cursor<int>(
          key: const ValueKey('cursor'),
          fetchPage: (cursor) async => const CursorPage(items: []),
          itemBuilder: (context, item, index) => Text('$item'),
          empty: const EmptyView(icon: Icons.history, title: 'No history'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('No history'), findsOneWidget);
  });

  testWidgets('ErrorView: not configured has no retry; network errors do', (tester) async {
    await tester.pumpWidget(
      wrap(
        ErrorView(
          error: const ApiException(status: 503, code: ApiErrorCode.serviceNotConfigured, message: 'Kavita is not configured'),
          onRetry: () {},
        ),
      ),
    );
    expect(find.text('Not configured on the hub'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
    await tester.pumpWidget(wrap(ErrorView(error: const ApiException.network(), onRetry: () {})));
    expect(find.byIcon(Icons.wifi_off), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('AsyncValueView keeps data and shows the stale banner when a refresh fails', (tester) async {
    var calls = 0;
    final provider = FutureProvider<String>((ref) async {
      calls++;
      if (calls > 1) throw const ApiException.network();
      return 'cached';
    });
    await tester.pumpWidget(
      wrap(
        Consumer(
          builder: (context, ref, _) => AsyncValueView<String>(value: ref.watch(provider), data: (context, v) => Text(v)),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('cached'), findsOneWidget);
    expect(find.textContaining("Couldn't refresh"), findsNothing);
    ProviderScope.containerOf(tester.element(find.text('cached'))).invalidate(provider);
    await tester.pump();
    await tester.pump();
    expect(find.text('cached'), findsOneWidget);
    expect(find.textContaining("Couldn't refresh"), findsOneWidget);
  });

  testWidgets('status chips use the theme extension colours', (tester) async {
    await tester.pumpWidget(wrap(StatusChip.health(ServiceHealthStatus.down)));
    final text = tester.widget<Text>(find.text('Down'));
    expect(text.style?.color, StatusColors.dark.error);
  });
}
