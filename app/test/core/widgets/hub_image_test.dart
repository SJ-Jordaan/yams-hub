import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yams_hub/core/auth/token_manager.dart';
import 'package:yams_hub/core/servers/server_connection.dart';
import 'package:yams_hub/core/widgets/hub_image.dart';

import '../../support/builders.dart';

const _path = '/api/v1/img/arr/sonarr/54/poster?size=250&v=63905';

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  ApiTransport transport = ApiTransport.cookie,
  String? token = 'yha_access1',
  double dpr = 2,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        activeServerProvider.overrideWith(
          () => ActiveServerController(
            fixed: ServerConnection(
              status: ConnectionStatus.connected,
              baseUrl: testLanUrl,
              transport: transport,
            ),
          ),
        ),
        accessTokenProvider.overrideWithValue(token),
      ],
      child: MediaQuery(
        data: MediaQueryData(devicePixelRatio: dpr),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Center(child: child),
        ),
      ),
    ),
  ); // The web path starts its fetch in a zero-length timer (DeferredNetworkImage).
  await tester.pump(Duration.zero);
}

void main() {
  group('web path', () {
    setUp(() => debugHubImageWebPath = true);
    tearDown(() => debugHubImageWebPath = false);

    testWidgets(
      'cookie transport: one deferred plain NetworkImage, no headers, /yh prefix',
      (tester) async {
        await _pump(tester, const HubImage(_path, width: 40, height: 60));
        expect(find.byType(CachedNetworkImage), findsNothing);
        expect(find.byType(Image), findsOneWidget);
        final image = tester.widget<Image>(find.byType(Image));
        // Not a ResizeImage: no second decode / resample on web.
        expect(image.image, isA<DeferredNetworkImage>());
        final provider = (image.image as DeferredNetworkImage).inner;
        expect(provider.headers, isNull);
        expect(provider.url, 'http://192.168.10.183:8090/yh$_path');
        expect(provider.webHtmlElementStrategy, WebHtmlElementStrategy.never);
        expect(image.opacity, isNull);
        expect(find.byType(FadeTransition), findsNothing);
      },
    );

    testWidgets('bearer transport sends the access token', (tester) async {
      await _pump(
        tester,
        const HubImage(_path, width: 40, height: 60),
        transport: ApiTransport.bearer,
      );
      final provider =
          (tester.widget<Image>(find.byType(Image)).image
                  as DeferredNetworkImage)
              .inner;
      expect(provider.headers, {'Authorization': 'Bearer yha_access1'});
      expect(provider.url, 'http://192.168.10.183:8090$_path');
    });

    testWidgets('opacity dims the image without an Opacity layer', (
      tester,
    ) async {
      await _pump(
        tester,
        const HubImage(_path, width: 40, height: 60, opacity: .45),
      );
      final image = tester.widget<Image>(find.byType(Image));
      expect(image.opacity?.value, .45);
      expect(find.byType(Opacity), findsNothing);
      expect(find.byType(FadeTransition), findsNothing);
    });

    testWidgets('a missing path shows the placeholder without a request', (
      tester,
    ) async {
      await _pump(tester, const HubImage(null, width: 40, height: 60));
      expect(find.byType(Image), findsNothing);
      expect(find.byIcon(Icons.image_outlined), findsOneWidget);
    });
  });

  group('native path', () {
    setUp(() => debugHubImageWebPath = false);

    testWidgets(
      'CachedNetworkImage decoded at height × dpr with the bearer header',
      (tester) async {
        await _pump(
          tester,
          const HubImage(_path, width: 40, height: 60),
          transport: ApiTransport.bearer,
        );
        final image = tester.widget<CachedNetworkImage>(
          find.byType(CachedNetworkImage),
        );
        expect(image.memCacheHeight, 120);
        expect(image.memCacheWidth, isNull);
        expect(image.httpHeaders, {'Authorization': 'Bearer yha_access1'});
        expect(image.cacheKey, _path);
        expect(image.imageUrl, 'http://192.168.10.183:8090$_path');
        expect(image.color, isNull);
      },
    );

    testWidgets('width × dpr when the height is unbounded; never both', (
      tester,
    ) async {
      await _pump(
        tester,
        const HubImage(_path, width: 100, height: double.infinity),
        transport: ApiTransport.bearer,
      );
      final image = tester.widget<CachedNetworkImage>(
        find.byType(CachedNetworkImage),
      );
      expect(image.memCacheHeight, isNull);
      expect(image.memCacheWidth, 200);
    });

    testWidgets('opacity is a colour modulation, not an Opacity layer', (
      tester,
    ) async {
      await _pump(
        tester,
        const HubImage(_path, width: 40, height: 60, opacity: .5),
        transport: ApiTransport.bearer,
      );
      final image = tester.widget<CachedNetworkImage>(
        find.byType(CachedNetworkImage),
      );
      expect(image.color, Colors.white.withValues(alpha: .5));
      expect(image.colorBlendMode, BlendMode.modulate);
      expect(find.byType(Opacity), findsNothing);
    });
  });

  group('DeferredNetworkImage', () {
    testWidgets(
      'starts the inner load only after the current task, then forwards the image',
      (tester) async {
        final image = await tester.runAsync(
          () => createTestImage(width: 2, height: 2),
        );
        var started = 0;
        final inner = _FakeProvider(image!, () => started++);
        final provider = DeferredNetworkImage(inner);
        final completer = provider.loadImage(
          inner,
          (b, {getTargetSize}) => throw UnimplementedError(),
        );
        ImageInfo? got;
        completer.addListener(ImageStreamListener((info, _) => got = info));
        expect(started, 0, reason: 'nothing starts inside the frame');
        await tester.pump(Duration.zero);
        expect(started, 1);
        expect(got?.image.width, 2);
        got?.dispose();
      },
    );

    testWidgets(
      'listens to the inner load only while it has listeners, keeping it alive',
      (tester) async {
        final image = await tester.runAsync(
          () => createTestImage(width: 2, height: 2),
        );
        final inner = _FakeProvider(image!, () {});
        final completer = DeferredNetworkImage(inner).loadImage(
          inner,
          (b, {getTargetSize}) => throw UnimplementedError(),
        );
        final cacheHandle = completer.keepAlive(); // as the ImageCache does
        var images = 0;
        final listener = ImageStreamListener((info, _) {
          images++;
          info.dispose();
        });
        completer.addListener(listener);
        await tester.pump(Duration.zero);
        final started = inner.last!;
        expect(images, 1);
        expect(started.listeners, 1);

        // Off screen (still cached): an animated inner image would stop.
        completer.removeListener(listener);
        expect(started.listeners, 0);
        expect(started.disposed, isFalse, reason: 'kept for the cache entry');

        // Back on screen: shown again at once.
        completer.addListener(listener);
        expect(started.listeners, 1);
        expect(images, greaterThanOrEqualTo(2));

        completer.removeListener(listener);
        cacheHandle.dispose(); // evicted
        expect(started.disposed, isTrue);
      },
    );

    test('equality and cache key follow the inner NetworkImage', () async {
      const a = DeferredNetworkImage(NetworkImage('http://h/x.jpg'));
      const b = DeferredNetworkImage(NetworkImage('http://h/x.jpg'));
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(
        await a.obtainKey(ImageConfiguration.empty),
        const NetworkImage('http://h/x.jpg'),
      );
    });
  });

  test('hubImageUrlFor matches hubImageUrl and rejects absolute paths', () {
    expect(
      hubImageUrlFor(_path, testLanUrl, ApiTransport.cookie),
      'http://192.168.10.183:8090/yh$_path',
    );
    expect(
      hubImageUrlFor(_path, testLanUrl, ApiTransport.bearer),
      'http://192.168.10.183:8090$_path',
    );
    expect(hubImageUrlFor(_path, null, ApiTransport.bearer), isNull);
    expect(
      hubImageUrlFor(
        'https://evil.example/x.jpg',
        testLanUrl,
        ApiTransport.bearer,
      ),
      isNull,
    );
    expect(
      hubImageUrlFor('//evil.example/x.jpg', testLanUrl, ApiTransport.bearer),
      isNull,
    );
  });
}

/// A [NetworkImage] whose load completes at once with [image].
class _FakeProvider extends ImageProvider<NetworkImage>
    implements NetworkImage {
  _FakeProvider(this.image, this.onStart);

  final ui.Image image;
  final VoidCallback onStart;

  /// The completer of the last load.
  _CountingCompleter? last;

  @override
  String get url => 'http://h/fake.jpg';
  @override
  double get scale => 1;
  @override
  Map<String, String>? get headers => null;
  @override
  WebHtmlElementStrategy get webHtmlElementStrategy =>
      WebHtmlElementStrategy.never;

  @override
  Future<NetworkImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    NetworkImage key,
    ImageDecoderCallback decode,
  ) {
    onStart();
    return last = _CountingCompleter(
      SynchronousFuture(ImageInfo(image: image.clone())),
    );
  }
}

/// A one-frame completer that counts its listeners.
class _CountingCompleter extends OneFrameImageStreamCompleter {
  _CountingCompleter(super.image);

  int listeners = 0;
  bool disposed = false;

  @override
  void addListener(ImageStreamListener listener) {
    listeners++;
    super.addListener(listener);
  }

  @override
  void removeListener(ImageStreamListener listener) {
    listeners--;
    super.removeListener(listener);
  }

  @override
  void onDisposed() {
    disposed = true;
    super.onDisposed();
  }
}
