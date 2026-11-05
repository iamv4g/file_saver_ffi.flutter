@TestOn('vm && !windows')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// `tool/ci_result.sh`, which decides the required `CI result` check.
void main() {
  final missing = [
    'bash',
    'jq',
  ].where((tool) => Process.runSync('which', [tool]).exitCode != 0);
  final skip = missing.isEmpty ? null : 'Needs ${missing.join(' and ')}';

  /// The `needs` context of a run whose change needs [scope]'s platforms,
  /// with [results] overriding the result of a job (all succeed otherwise).
  Map<String, Object?> needs({
    Map<String, String> scope = const {},
    Map<String, String> results = const {},
  }) {
    final outputs = {
      'android': 'false',
      'darwin': 'false',
      'web': 'false',
      'build': '[]',
      ...scope,
    };
    String result(String job, {required bool runs}) =>
        results[job] ?? (runs ? 'success' : 'skipped');
    return {
      'changes': {'result': result('changes', runs: true), 'outputs': outputs},
      'analyze': {'result': result('analyze', runs: true)},
      'test': {'result': result('test', runs: true)},
      'android-unit-test': {
        'result': result(
          'android-unit-test',
          runs: outputs['android'] == 'true',
        ),
      },
      'android-consumer': {
        'result': result(
          'android-consumer',
          runs: outputs['android'] == 'true',
        ),
      },
      'darwin-unit-test': {
        'result': result('darwin-unit-test', runs: outputs['darwin'] == 'true'),
      },
      'web-test': {
        'result': result('web-test', runs: outputs['web'] == 'true'),
      },
      'build': {'result': result('build', runs: outputs['build'] != '[]')},
    };
  }

  Future<ProcessResult> check(Map<String, Object?> needs) async {
    final process = await Process.start('bash', ['tool/ci_result.sh']);
    process.stdin.write(jsonEncode(needs));
    await process.stdin.close();
    final out = await process.stdout.transform(utf8.decoder).join();
    final err = await process.stderr.transform(utf8.decoder).join();
    return ProcessResult(process.pid, await process.exitCode, out, err);
  }

  const darwin = {
    'darwin': 'true',
    'build': '[{"os":"macos-latest","target":"macos"}]',
  };

  group('passes', skip: skip, () {
    test('when every job succeeds', () async {
      expect((await check(needs(scope: darwin))).exitCode, 0);
    });

    test('when a platform job the change does not need is skipped', () async {
      final result = await check(needs());

      expect(result.exitCode, 0);
      expect(result.stdout, contains('darwin-unit-test: skipped'));
    });
  });

  group('fails', skip: skip, () {
    // `abandoned` is what GitHub reports for a job no runner picked up.
    for (final outcome in [
      'failure',
      'cancelled',
      'abandoned',
      'skipped',
      '',
    ]) {
      test('when a job the change needs ends "$outcome"', () async {
        final result = await check(
          needs(scope: darwin, results: {'darwin-unit-test': outcome}),
        );

        expect(result.exitCode, 1);
        expect(result.stdout, contains('darwin-unit-test ($outcome)'));
      });
    }

    test('when a job that always runs is skipped', () async {
      final result = await check(needs(results: {'test': 'skipped'}));

      expect(result.exitCode, 1);
      expect(result.stdout, contains('test (skipped)'));
    });

    test('when the changes job fails, and the platform jobs are skipped '
        'with it', () async {
      final needed = needs(results: {'changes': 'failure'});
      (needed['changes']! as Map)['outputs'] = <String, String>{};

      final result = await check(needed);

      expect(result.exitCode, 1);
      expect(result.stdout, contains('changes (failure)'));
    });
  });
}
