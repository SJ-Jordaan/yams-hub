import 'dart:async';

import 'package:test/test.dart';
import 'package:yams_hub_updater/yams_hub_updater.dart';

import 'support/fake_process_runner.dart';

void main() {
  final commands = ComposeCommands(UpdaterConfig(token: 't' * 48));
  var ids = 0;
  JobManager make(FakeProcessRunner runner, {int keepFinished = 50}) =>
      JobManager(
        runner: runner,
        stepTimeout: const Duration(minutes: 15),
        keepFinished: keepFinished,
        newId: () => 'j_test${ids++}',
      );

  test('runs every step in order and succeeds', () async {
    final runner = FakeProcessRunner()
      ..on(' pull ', () => FakeReply(stdout: ['sonarr Pulled']))
      ..on(' up ', () => FakeReply(stderr: ['Container sonarr  Started']));
    final jobs = make(runner);
    final job = jobs.start(
      kind: JobKind.update,
      service: 'sonarr',
      plan: commands.updatePlan('sonarr'),
    );
    expect(job.state, JobState.queued);
    expect(jobs.active, same(job));
    await job.done;

    expect(job.state, JobState.succeeded);
    expect(jobs.active, isNull);
    expect(
      [for (final c in runner.calls) c.argv],
      [for (final s in commands.updatePlan('sonarr')) s.argv],
    );
    expect(
      runner.calls.every((c) => c.timeout == const Duration(minutes: 15)),
      isTrue,
    );
    expect(job.log, contains('sonarr Pulled'));
    expect(job.log, contains('Container sonarr  Started'));
    expect(job.log.first, startsWith(r'$ docker compose -p yams'));

    final json = job.toJson();
    expect(json['id'], job.id);
    expect(json['service'], 'sonarr');
    expect(json['kind'], 'update');
    expect(json['state'], 'succeeded');
    final steps = json['steps']! as List<Object?>;
    expect(steps, hasLength(3));
    final first = steps.first! as Map<String, Object?>;
    expect(
      first['cmd'],
      startsWith('docker compose -p yams --project-directory /opt/yams'),
    );
    expect(first['cmd'], endsWith('pull -- sonarr'));
    expect(first['exitCode'], 0);
    expect(first['startedAt'], endsWith('Z'));
    expect(first['finishedAt'], endsWith('Z'));
    expect(json['startedAt'], isA<String>());
    expect(json['finishedAt'], isA<String>());
  });

  test('a failing step stops the job; later steps never run', () async {
    final runner = FakeProcessRunner()
      ..on(
        ' pull ',
        () => FakeReply(exitCode: 18, stderr: ['manifest unknown']),
      );
    final jobs = make(runner);
    final job = jobs.start(
      kind: JobKind.update,
      service: 'sonarr',
      plan: commands.updatePlan('sonarr'),
    );
    await job.done;
    expect(job.state, JobState.failed);
    expect(job.error, 'Pull sonarr failed');
    expect(runner.calls, hasLength(1));
    final json = job.toJson();
    final steps = json['steps']! as List<Object?>;
    expect(
      steps,
      hasLength(1),
      reason: 'steps that never started are not listed',
    );
    expect((steps[0]! as Map)['exitCode'], 18);
    expect(json['stepCount'], 3);
  });

  test('a failing optional prune does not fail the update', () async {
    final runner = FakeProcessRunner()
      ..on('image prune', () => FakeReply(exitCode: 1));
    final jobs = make(runner);
    final job = jobs.start(
      kind: JobKind.update,
      service: 'radarr',
      plan: commands.updatePlan('radarr'),
    );
    await job.done;
    expect(job.state, JobState.succeeded);
    expect(job.log.any((l) => l.contains('optional')), isTrue);
  });

  test('timeouts and start errors fail the job', () async {
    final runner = FakeProcessRunner()
      ..on(' pull ', () => FakeReply(timedOut: true, exitCode: -15));
    final jobs = make(runner);
    final job = jobs.start(
      kind: JobKind.update,
      service: 'sonarr',
      plan: commands.updatePlan('sonarr'),
    );
    await job.done;
    expect(job.state, JobState.failed);
    expect(job.error, 'Pull sonarr timed out');
    expect(
      (job.toJson()['steps']! as List).first,
      containsPair('timedOut', true),
    );

    final runner2 = FakeProcessRunner()
      ..on(
        'docker',
        () => FakeReply(startError: 'cannot start docker: No such file'),
      );
    final job2 = make(runner2).start(
      kind: JobKind.recyclarrSync,
      service: 'recyclarr',
      plan: ComposeCommands.recyclarrSyncPlan,
    );
    await job2.done;
    expect(job2.state, JobState.failed);
    expect(job2.log, contains('cannot start docker: No such file'));
  });

  test('one job at a time', () async {
    final gate = Completer<void>();
    final runner = FakeProcessRunner()
      ..on(' pull ', () => FakeReply(gate: gate));
    final jobs = make(runner);
    final first = jobs.start(
      kind: JobKind.update,
      service: 'sonarr',
      plan: commands.updatePlan('sonarr'),
    );
    await Future<void>.delayed(Duration.zero);
    expect(first.state, JobState.running);
    expect(
      () => jobs.start(
        kind: JobKind.recyclarrSync,
        service: 'recyclarr',
        plan: ComposeCommands.recyclarrSyncPlan,
      ),
      throwsA(
        isA<JobBusyException>().having((e) => e.activeJobId, 'id', first.id),
      ),
    );
    gate.complete();
    await first.done;
    final second = jobs.start(
      kind: JobKind.recyclarrSync,
      service: 'recyclarr',
      plan: ComposeCommands.recyclarrSyncPlan,
    );
    await second.done;
    expect(second.state, JobState.succeeded);
    expect(jobs[first.id], same(first));
  });

  test('log keeps the last 500 lines', () async {
    final runner = FakeProcessRunner()
      ..on(
        ' pull ',
        () => FakeReply(stdout: [for (var i = 0; i < 800; i++) 'line $i']),
      );
    final jobs = make(runner);
    final job = jobs.start(
      kind: JobKind.update,
      service: 'sonarr',
      plan: commands.updatePlan('sonarr'),
    );
    await job.done;
    expect(job.log, hasLength(500));
    expect(job.log.last, startsWith('Prune dangling images: ok'));
    expect(job.log, isNot(contains('line 0')));
  });

  test('old finished jobs are forgotten', () async {
    final runner = FakeProcessRunner();
    final jobs = make(runner, keepFinished: 2);
    final done = <UpdaterJob>[];
    for (var i = 0; i < 4; i++) {
      final j = jobs.start(
        kind: JobKind.recyclarrSync,
        service: 'recyclarr',
        plan: ComposeCommands.recyclarrSyncPlan,
      );
      await j.done;
      done.add(j);
    }
    expect(jobs[done[0].id], isNull);
    expect(jobs[done[1].id], isNull);
    expect(jobs[done[2].id], same(done[2]));
    expect(jobs[done[3].id], same(done[3]));
  });

  test('default ids are j_ + 16 hex characters', () {
    final jobs = JobManager(runner: FakeProcessRunner());
    final job = jobs.start(
      kind: JobKind.recyclarrSync,
      service: 'recyclarr',
      plan: ComposeCommands.recyclarrSyncPlan,
    );
    expect(job.id, matches(RegExp(r'^j_[0-9a-f]{16}$')));
    expect(jobIdPattern.hasMatch(job.id), isTrue);
  });
}
