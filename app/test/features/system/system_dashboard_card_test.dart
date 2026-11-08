import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yams_hub/core/routing/router.dart';
import 'package:yams_hub/core/theme/theme.dart';
import 'package:yams_hub/core/widgets/widgets.dart';
import 'package:yams_hub/features/system/system_dashboard_card.dart';
import 'package:yams_models/yams_models.dart';

import '../../support/builders.dart';
import '../../support/pump_hub_app.dart';
import 'system_samples.dart';

Widget _wrap(Widget child) => ProviderScope(
  child: MaterialApp(
    theme: buildHubTheme(seededScheme(const Color(0xFF7C4DFF), Brightness.dark)),
    home: Scaffold(body: SizedBox(width: 380, child: child)),
  ),
);

void main() {
  testWidgets('renders CPU, sparkline, temperature, bars, RAID, network and monitors', (tester) async {
    await tester.pumpWidget(_wrap(SystemDashboardCard(section: buildSection(buildSystemCard().toJson()))));
    expect(find.text('22 %'), findsOneWidget);
    expect(find.byKey(const Key('systemCard.sparkline')), findsOneWidget);
    expect(find.byType(Sparkline), findsOneWidget);
    expect(find.text('68 °C'), findsOneWidget);
    expect(find.text('Memory'), findsOneWidget);
    expect(find.text('4.8 GiB / 7.5 GiB'), findsOneWidget);
    expect(find.text('/volume1'), findsOneWidget);
    expect(find.text('3.5 TiB / 7.2 TiB · 49 %'), findsOneWidget);
    expect(find.text('RAID0 · active'), findsOneWidget);
    expect(find.byTooltip('No redundancy: one disk failure loses all data. Keep backups.'), findsOneWidget);
    expect(find.text('120 kB/s'), findsOneWidget);
    expect(find.text('2.4 MB/s'), findsOneWidget);
    expect(find.byIcon(Icons.arrow_downward), findsOneWidget);
    expect(find.byTooltip('Tailscale: remote use'), findsOneWidget);
    expect(find.text('20/21 up'), findsOneWidget);
    expect(find.text('up 2h 52m'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('RAID not active is red; down monitors turn the chip red', (tester) async {
    await tester.pumpWidget(
      _wrap(
        SystemDashboardCard(
          section: buildSection(buildSystemCard(raidHealthy: false, down: 2, tailscale: false).toJson()),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('RAID0 · inactive'), findsOneWidget);
    expect(find.text('18/21 up'), findsOneWidget);
    expect(find.byTooltip('Tailscale: idle'), findsOneWidget);
    final context = tester.element(find.text('RAID0 · inactive'));
    final raidChip = tester.widget<StatusChip>(
      find.ancestor(of: find.text('RAID0 · inactive'), matching: find.byType(StatusChip)),
    );
    expect(raidChip.tone, StatusTone.error);
    final monitorsChip = tester.widget<StatusChip>(find.byKey(const Key('systemCard.monitors')));
    expect(monitorsChip.tone, StatusTone.error);
    expect(StatusColors.of(context).forTone(raidChip.tone), StatusColors.of(context).error);
  });

  testWidgets('optional parts are left out', (tester) async {
    const card = SystemCard(memUsedBytes: 1 << 30, memTotalBytes: 8 << 30, uptimeSeconds: 0);
    await tester.pumpWidget(_wrap(SystemDashboardCard(section: buildSection(card.toJson()))));
    expect(find.text('–'), findsOneWidget); // CPU % before the second sample
    expect(find.byKey(const Key('systemCard.temp')), findsNothing);
    expect(find.byKey(const Key('systemCard.volume')), findsNothing);
    expect(find.byKey(const Key('systemCard.raid')), findsNothing);
    expect(find.byKey(const Key('systemCard.net')), findsNothing);
    expect(find.byKey(const Key('systemCard.monitors')), findsNothing);
    expect(find.text('Memory'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('on the dashboard; tap opens /system', (tester) async {
    final api = buildCoreFakeApi()
      ..getJson(
        '/dashboard',
        buildDashboardJson(cards: {DashboardCardKeys.system: buildSection(buildSystemCard().toJson()).toJson()}),
      );
    serveSystem(api);
    final app = await pumpHubApp(tester, api: api);
    expect(find.byKey(const Key('systemCard.cpu')), findsOneWidget);
    await tester.tap(find.byKey(const Key('systemCard.cpu')));
    await settle(tester);
    expect(app.container.read(routerProvider).routerDelegate.currentConfiguration.uri.toString(), '/system');
    expect(find.text('Host'), findsWidgets);
  });
}
