import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yams_hub/core/settings/app_settings.dart';
import 'package:yams_hub/features/requests/data/requests_api.dart';
import 'package:yams_hub/features/requests/providers/requests_providers.dart';
import 'package:yams_hub/features/requests/widgets/request_ui.dart';
import 'package:yams_models/yams_models.dart';

import '../../support/fake_api.dart';
import 'requests_samples.dart';

Future<ProviderContainer> _container(FakeApi api) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final dio = Dio(BaseOptions(baseUrl: 'http://192.168.10.183:8090/api/v1'))..httpClientAdapter = api;
  final container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      requestsApiProvider.overrideWithValue(RequestsApi(dio)),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

FakeResponse _pagedRequests(RequestOptions r, {int total = 40}) {
  final p = int.parse(r.uri.queryParameters['page']!);
  final size = int.parse(r.uri.queryParameters['pageSize']!);
  final start = (p - 1) * size;
  final count = (total - start).clamp(0, size);
  return FakeResponse(
    PagedList.of(
      items: [for (var i = 0; i < count; i++) request(start + i + 1)],
      page: p,
      pageSize: size,
      total: total,
    ).toJson((r) => r.toJson()),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PagedController', () {
    test('loads more, and a refresh reloads every page loaded so far', () async {
      final api = FakeApi()..on('GET', '/requests', _pagedRequests);
      final c = await _container(api);
      final sub = c.listen(requestsListProvider(RequestsTab.all), (_, _) {});
      addTearDown(sub.close);
      final first = await c.read(requestsListProvider(RequestsTab.all).future);
      expect(first.items, hasLength(25));
      expect(first.hasMore, isTrue);

      await c.read(requestsListProvider(RequestsTab.all).notifier).loadMore();
      final both = c.read(requestsListProvider(RequestsTab.all)).value!;
      expect(both.items, hasLength(40));
      expect(both.hasMore, isFalse);
      expect(both.items.last.id, 40);

      api.requests.clear();
      await c.read(requestsListProvider(RequestsTab.all).notifier).refresh();
      expect(api.requests.map((r) => r.uri.queryParameters['page']), ['1', '2']);
      expect(c.read(requestsListProvider(RequestsTab.all)).value!.items, hasLength(40));
    });

    test('a write elsewhere (generation bump) reloads the list', () async {
      final api = FakeApi()..on('GET', '/requests', (r) => _pagedRequests(r, total: 3));
      final c = await _container(api);
      final sub = c.listen(requestsListProvider(RequestsTab.pending), (_, _) {});
      addTearDown(sub.close);
      await c.read(requestsListProvider(RequestsTab.pending).future);
      expect(api.requests.single.uri.queryParameters['filter'], 'pending');
      c.read(requestsGenerationProvider.notifier).bump();
      await c.read(requestsListProvider(RequestsTab.pending).future);
      expect(api.requests, hasLength(2));
    });

    test('removeLocally drops a row and keeps the total consistent', () async {
      final api = FakeApi()..on('GET', '/requests', (r) => _pagedRequests(r, total: 3));
      final c = await _container(api);
      final sub = c.listen(requestsListProvider(RequestsTab.pending), (_, _) {});
      addTearDown(sub.close);
      await c.read(requestsListProvider(RequestsTab.pending).future);
      c.read(requestsListProvider(RequestsTab.pending).notifier).removeLocally((r) => r.id == 2);
      final v = c.read(requestsListProvider(RequestsTab.pending)).value!;
      expect(v.items.map((r) => r.id), [1, 3]);
      expect(v.total, 2);
    });

    test('mine sends mine=true', () async {
      final api = FakeApi()..on('GET', '/requests', (r) => _pagedRequests(r, total: 0));
      final c = await _container(api);
      final sub = c.listen(requestsListProvider(RequestsTab.mine), (_, _) {});
      addTearDown(sub.close);
      await c.read(requestsListProvider(RequestsTab.mine).future);
      expect(api.requests.single.uri.queryParameters, containsPair('mine', 'true'));
    });
  });

  test('IssueController posts comments and keeps the returned issue', () async {
    final api = FakeApi()
      ..getJson('/issues/11', issue(11, commentCount: 0).toJson())
      ..postJson('/issues/11/comments', issue(11, commentCount: 1).toJson())
      ..postJson('/issues/11/resolve', issue(11, status: IssueStatus.resolved).toJson());
    final c = await _container(api);
    final sub = c.listen(issueProvider(11), (_, _) {});
    addTearDown(sub.close);
    await c.read(issueProvider(11).future);
    final generation = c.read(requestsGenerationProvider);
    await c.read(issueProvider(11).notifier).comment('hello');
    expect(c.read(issueProvider(11)).value!.commentCount, 1);
    expect(api.requestsTo('/issues/11/comments').single.data, {'message': 'hello'});
    await c.read(issueProvider(11).notifier).resolve();
    expect(c.read(issueProvider(11)).value!.status, IssueStatus.resolved);
    expect(c.read(requestsGenerationProvider), generation + 2);
  });

  test('watchlist is filtered on the device by media type', () async {
    final api = FakeApi()..getJson('/discover/watchlist', page([card(1, 'A'), card(2, 'B', type: MediaType.tv)]));
    final c = await _container(api);
    final p = await c.read(discoverProvider((slider: DiscoverSlider.watchlist, mediaType: MediaType.tv)).future);
    expect(p.items.map((i) => i.title), ['B']);
    expect(api.requests.single.uri.queryParameters.containsKey('mediaType'), isFalse);
  });

  group('labels', () {
    test('quota lines', () {
      expect(quotaLine(const QuotaInfo(), MediaType.movie), isNull, reason: 'unlimited');
      expect(
        quotaLine(const QuotaInfo(limit: 5, days: 7, used: 2, remaining: 3), MediaType.movie),
        '3 of 5 movie requests left this week',
      );
      expect(
        quotaLine(const QuotaInfo(limit: 2, days: 14, used: 1, remaining: 1), MediaType.tv),
        '1 of 2 series requests left in 14 days',
      );
      expect(
        quotaLine(const QuotaInfo(limit: 5, days: 7, used: 5, remaining: 0, restricted: true), MediaType.movie),
        'No movie requests left (limit 5 every 7 days)',
      );
      expect(quotaBlocks(const QuotaInfo(limit: 5, used: 5, remaining: 0, restricted: true)), isTrue);
      expect(quotaBlocks(const QuotaInfo()), isFalse);
    });

    test('request display status', () {
      expect(requestDisplay(request(1)).label, 'Pending');
      expect(
        requestDisplay(request(1, status: RequestStatus.approved, availability: Availability.processing)).label,
        'Processing',
      );
      expect(
        requestDisplay(request(1, status: RequestStatus.approved, availability: Availability.available)).label,
        'Available',
      );
      expect(requestDisplay(request(1, status: RequestStatus.failed)).label, 'Failed');
      expect(requestDisplay(request(1, status: RequestStatus.declined)).label, 'Declined');
    });

    test('season labels and result messages', () {
      expect(seasonsLabel([2, 1]), 'S1 S2');
      expect(seasonsLabel([1, 2, 3, 4, 5, 6, 7]), 'S1–S7');
      expect(
        requestResultMessage(
          const CreateRequestResult(outcome: CreateRequestOutcome.created),
          type: MediaType.tv,
          isAdmin: false,
        ),
        'Requested · waiting for approval',
      );
      expect(
        requestResultMessage(
          const CreateRequestResult(outcome: CreateRequestOutcome.autoApproved),
          type: MediaType.tv,
          isAdmin: true,
        ),
        'Requested · sent to Sonarr',
      );
      expect(
        requestResultMessage(
          const CreateRequestResult(outcome: CreateRequestOutcome.nothingToRequest),
          type: MediaType.tv,
          isAdmin: true,
        ),
        'Everything is already requested',
      );
    });
  });
}
