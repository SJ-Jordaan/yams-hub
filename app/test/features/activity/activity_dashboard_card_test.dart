import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yams_hub/core/auth/auth_controller.dart';
import 'package:yams_hub/core/theme/theme.dart';
import 'package:yams_hub/features/activity/activity_dashboard_card.dart';
import 'package:yams_models/yams_models.dart';

import '../../support/builders.dart';
import 'activity_samples.dart';

Widget _wrap(Widget child, {bool admin = true}) => ProviderScope(
  retry: (_, _) => null,
  overrides: [isAdminProvider.overrideWithValue(admin)],
  child: MaterialApp(
    theme: buildHubTheme(seededScheme(const Color(0xFF7C4DFF), Brightness.dark)),
    home: Scaffold(body: SingleChildScrollView(child: child)),
  ),
);

void main() {
  testWidgets('shows speeds, counts, top items and the VPN line', (tester) async {
    final card = ActivityCard(
      transfer: const ActivityCardTransfer(
        dlBps: 4800000,
        upBps: 906283,
        altSpeedEnabled: true,
        connectionStatus: TransferConnectionStatus.connected,
      ),
      counts: const ActivityCardCounts(downloading: 1, seeding: 12, stalled: 1, attention: 1),
      top: [buildAttentionItem(), buildDownloadingItem()],
      vpn: buildVpn(),
    );
    await tester.pumpWidget(_wrap(ActivityDashboardCard(section: buildSection(card.toJson()))));
    expect(find.text('4.8 MB/s'), findsOneWidget);
    expect(find.text('906 kB/s'), findsOneWidget);
    expect(find.text('Alt speed'), findsOneWidget);
    expect(find.text('12'), findsOneWidget);
    expect(find.text('Seeding'), findsOneWidget);
    expect(find.text('That Time I Got Reincarnated as a Slime'), findsOneWidget);
    expect(find.text('Manual import needed'), findsOneWidget);
    expect(find.text('Dune: Part Two'), findsOneWidget);
    expect(find.text('42 % · 41m 10s'), findsOneWidget);
    expect(find.text('VPN · France · port 36681 ✓'), findsOneWidget);
  });

  testWidgets('a tracker-error item is labelled in red', (tester) async {
    final item = buildDownloadingItem();
    final card = ActivityCard(
      counts: const ActivityCardCounts(downloading: 1, seeding: 0, stalled: 0, attention: 1),
      top: [
        QueueItem.fromJson({
          ...item.toJson(),
          'needsAttention': true,
          'attention': QueueAttention.trackerError.toJson(),
        }),
      ],
    );
    await tester.pumpWidget(_wrap(ActivityDashboardCard(section: buildSection(card.toJson()))));
    final label = find.text('Tracker error');
    expect(label, findsOneWidget);
    expect(tester.widget<Text>(label).style?.color, StatusColors.of(tester.element(label)).error);
  });

  testWidgets('VPN down is shown in red', (tester) async {
    final card = ActivityCard(vpn: buildVpn(status: VpnConnectionState.down));
    await tester.pumpWidget(_wrap(ActivityDashboardCard(section: buildSection(card.toJson()))));
    final text = tester.widget<Text>(find.text('VPN down'));
    final element = tester.element(find.text('VPN down'));
    expect(text.style?.color, StatusColors.of(element).error);
  });

  testWidgets('partial data (badge-only sections) still renders', (tester) async {
    await tester.pumpWidget(
      _wrap(
        ActivityDashboardCard(
          section: buildSection({
            'counts': {'downloading': 2, 'seeding': 5, 'stalled': 0, 'attention': 2},
          }),
        ),
      ),
    );
    expect(find.text('Attention'), findsOneWidget);
    expect(find.text('5'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
