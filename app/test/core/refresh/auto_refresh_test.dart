import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yams_hub/core/refresh/auto_refresh.dart';
import 'package:yams_hub/core/settings/app_settings.dart';

void main() {
  testWidgets('a refresh due while paused waits for resume, then runs once after the delay', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(overrides: [sharedPreferencesProvider.overrideWithValue(prefs)]);
    addTearDown(container.dispose);

    var builds = 0;
    final provider = Provider.autoDispose<int>((ref) {
      autoRefresh(ref, const Duration(seconds: 10));
      return ++builds;
    });

    final sub = container.listen(provider, (_, _) {});
    expect(builds, 1);

    // Visible: refreshes on the interval.
    await tester.pump(const Duration(seconds: 10));
    container.read(provider);
    expect(builds, 2);

    // Hidden (an inactive tab): the due refresh is only remembered.
    sub.pause();
    await tester.pump(const Duration(seconds: 35));
    expect(builds, 2);

    // Back: nothing at once, exactly one refresh after the delay.
    sub.resume();
    await tester.pump();
    expect(builds, 2);
    await tester.pump(autoRefreshResumeDelay - const Duration(milliseconds: 1));
    expect(builds, 2);
    await tester.pump(const Duration(milliseconds: 1));
    container.read(provider);
    expect(builds, 3);
    await tester.pump(const Duration(seconds: 1));
    expect(builds, 3);
    container.dispose(); // cancels the interval timer before the pending-timer check
  });

  testWidgets('resuming without a missed refresh does not refetch', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(overrides: [sharedPreferencesProvider.overrideWithValue(prefs)]);
    addTearDown(container.dispose);

    var builds = 0;
    final provider = Provider.autoDispose<int>((ref) {
      autoRefresh(ref, const Duration(seconds: 10));
      return ++builds;
    });
    final sub = container.listen(provider, (_, _) {});
    sub.pause();
    await tester.pump(const Duration(seconds: 2));
    sub.resume();
    await tester.pump(const Duration(seconds: 1));
    expect(builds, 1);
    // The interval timer still runs from the last build.
    await tester.pump(const Duration(seconds: 7));
    container.read(provider);
    expect(builds, 2);
    container.dispose();
  });
}
