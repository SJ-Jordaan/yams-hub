import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yams_hub/core/auth/auth_controller.dart';
import 'package:yams_hub/core/theme/theme.dart';
import 'package:yams_hub/features/activity/providers/activity_providers.dart';
import 'package:yams_hub/features/activity/widgets/activity_format.dart';
import 'package:yams_hub/features/activity/widgets/vpn_sheet.dart';
import 'package:yams_models/yams_models.dart';

import 'activity_samples.dart';

VpnStatus _unreadable() => VpnStatus.fromJson({...buildVpn(port: null).toJson(), 'portForwardReadable': false});

Future<void> _pump(WidgetTester tester, VpnStatus v) => tester.pumpWidget(
  ProviderScope(
    retry: (_, _) => null,
    overrides: [isAdminProvider.overrideWithValue(false), vpnProvider.overrideWith((ref) async => v)],
    child: MaterialApp(
      theme: buildHubTheme(seededScheme(const Color(0xFF7C4DFF), Brightness.dark)),
      home: const Scaffold(body: VpnSheet()),
    ),
  ),
);

void main() {
  group('forwarded port Gluetun did not allow (issue #8)', () {
    test('format helpers say Unknown, not None yet / No', () {
      final v = _unreadable();
      expect(vpnForwardedPortText(v), "Unknown (Gluetun didn't allow it)");
      expect(vpnPortInSyncChip(v), ('Unknown', StatusTone.neutral));
      expect(vpnSummary(v), 'VPN · France · port unknown');
    });

    test('a refused public IP route is Unknown too', () {
      final v = VpnStatus.fromJson({...buildVpn().toJson(), 'publicIpReadable': false}..remove('publicIp'));
      expect(vpnPublicIpText(v), "Unknown (Gluetun didn't allow it)");
      expect(vpnPublicIpText(buildVpn()), '203.0.113.10');
      expect(vpnPublicIpText(buildVpn(status: VpnConnectionState.down)), 'None (reconnecting?)');
    });

    test('a readable port keeps the old texts', () {
      expect(vpnForwardedPortText(buildVpn(port: null)), 'None yet');
      expect(vpnPortInSyncChip(buildVpn(port: null)), ('No', StatusTone.warning));
      expect(vpnForwardedPortText(buildVpn()), '36681');
      expect(vpnPortInSyncChip(buildVpn()), ('Yes', StatusTone.ok));
    });

    testWidgets('the VPN sheet shows Unknown', (tester) async {
      await _pump(tester, _unreadable());
      await tester.pumpAndSettle();
      expect(find.text("Unknown (Gluetun didn't allow it)"), findsOneWidget);
      expect(find.text('Unknown'), findsOneWidget);
      expect(find.text('None yet'), findsNothing);
      expect(find.text('No'), findsNothing);
    });

    testWidgets('the VPN sheet shows an unknown public IP', (tester) async {
      await _pump(tester, VpnStatus.fromJson({...buildVpn().toJson(), 'publicIpReadable': false}..remove('publicIp')));
      await tester.pumpAndSettle();
      expect(find.text("Unknown (Gluetun didn't allow it)"), findsOneWidget);
      expect(find.text('None (reconnecting?)'), findsNothing);
      expect(find.text('Yes'), findsOneWidget);
    });
  });
}
