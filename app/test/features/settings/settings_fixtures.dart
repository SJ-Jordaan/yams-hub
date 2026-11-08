/// Gateway-shaped samples for the settings tests (API.md §2.2, §2.3).
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yams_models/yams_models.dart';

import '../../support/builders.dart';
import '../../support/fake_api.dart';
import '../../support/pump_hub_app.dart';

const adaId = 'u_1a2b3c4d5e6f';
const bobId = 'u_b0b0b0b0b0b0';
const carolId = 'u_ca401ca401ca';
const daveId = 'u_da7eda7eda7e';

const jfBob = '0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b';
const jfCarol = 'ca401ca401ca401ca401ca401ca401ca';
const jfEve = 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee';

User hubUser(
  String id,
  String name, {
  Role role = Role.member,
  String? jellyfinUserId,
  bool disabled = false,
}) => User(
  id: id,
  username: name.toLowerCase(),
  displayName: name,
  role: role,
  jellyfinUserId: jellyfinUserId,
  disabled: disabled,
  createdAt: testNow.subtract(const Duration(days: 30)),
  updatedAt: testNow,
);

/// Ada (admin, you), Bob (member, in Seerr), Carol (member, Jellyfin user
/// without Seerr account), Dave (member, no link, disabled).
List<User> sampleUsers() => [
  hubUser(adaId, 'Ada', role: Role.admin),
  hubUser(bobId, 'Bob', jellyfinUserId: jfBob),
  hubUser(carolId, 'Carol', jellyfinUserId: jfCarol),
  hubUser(daveId, 'Dave', disabled: true),
];

List<JellyfinUserOption> sampleJellyfinUsers({bool carolImported = false}) => [
  const JellyfinUserOption(
    jellyfinUserId: jfBob,
    name: 'bob',
    seerrUserId: 2,
    seerrDisplayName: 'Bob',
    linkedHubUserId: bobId,
  ),
  JellyfinUserOption(
    jellyfinUserId: jfCarol,
    name: 'carol',
    seerrUserId: carolImported ? 7 : null,
    seerrDisplayName: carolImported ? 'carol' : null,
    linkedHubUserId: carolId,
  ),
  const JellyfinUserOption(jellyfinUserId: jfEve, name: 'eve', isAdministrator: true),
];

SessionInfo sampleSession(
  String id, {
  String device = 'Pixel 8',
  ClientPlatform platform = ClientPlatform.android,
  bool current = false,
  Duration ago = Duration.zero,
  String? username,
  String userId = adaId,
}) => SessionInfo(
  id: id,
  userId: userId,
  deviceName: device,
  platform: platform,
  createdAt: testNow.subtract(const Duration(days: 3)),
  lastSeenAt: DateTime.now().toUtc().subtract(ago),
  lastIp: '192.168.10.50',
  expiresAt: testNow.add(const Duration(days: 30)),
  current: current,
  username: username,
);

AuditEntry auditEntry(
  String id,
  String action, {
  AuditOutcome outcome = AuditOutcome.ok,
  String? target,
  JsonMap? params,
  String? errorCode,
}) => AuditEntry(
  id: id,
  at: DateTime.now().toUtc().subtract(const Duration(minutes: 5)),
  userId: adaId,
  username: 'ada',
  sessionId: testSessionId,
  ip: '192.168.10.50',
  action: action,
  target: target,
  params: params,
  outcome: outcome,
  errorCode: errorCode,
  durationMs: 42,
);

JsonMap itemList(Iterable<JsonMap> items) => {'items': items.toList()};

/// The core fake plus the account/admin endpoints with sample data.
FakeApi settingsFakeApi({Role role = Role.admin}) => buildCoreFakeApi(role: role)
  ..getJson('/admin/users', itemList(sampleUsers().map((u) => u.toJson())))
  ..getJson('/admin/jellyfin-users', itemList(sampleJellyfinUsers().map((o) => o.toJson())));

/// Scrolls the page's list until [finder] is built and centred, then taps it
/// (the shell's navigation bar covers the bottom of the page).
Future<void> tapInList(WidgetTester tester, Finder finder) async {
  await scrollToCenter(tester, finder);
  await tester.tap(finder);
  await settle(tester);
}

/// Scrolls the page's main list ([delta] < 0 scrolls up) until [finder] is
/// built, then centres it.
Future<void> scrollToCenter(WidgetTester tester, Finder finder, {double delta = 150}) async {
  await tester.scrollUntilVisible(finder, delta, scrollable: find.byType(Scrollable).first);
  await tester.runAsync(() => Scrollable.ensureVisible(tester.element(finder), alignment: 0.5));
  await tester.pump();
}
