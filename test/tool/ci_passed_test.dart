@TestOn('vm && !windows')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// `tool/ci_passed.sh`, with which publish.yml skips CI on a tagged commit
/// that has passed it already.
void main() {
  final missing = [
    'bash',
    'jq',
  ].where((tool) => Process.runSync('which', [tool]).exitCode != 0);
  final skip = missing.isEmpty ? null : 'Needs ${missing.join(' and ')}';

  const sha = 'e70597724aa6368d4b2beb827fe748b7b39ea290';
  late Directory bin;

  setUp(() {
    bin = Directory.systemTemp.createTempSync('ci_passed_test');
    // A gh that answers `gh api <endpoint> --jq <filter>` with the runs in
    // $RUNS, filtered by the real jq, and logs the endpoint.
    File('${bin.path}/gh')
      ..writeAsStringSync(r'''
#!/usr/bin/env bash
echo "$2" >> "$GH_LOG"
jq -r "$4" <<<"$RUNS"
''')
      ..createSync();
    Process.runSync('chmod', ['+x', '${bin.path}/gh']);
  });

  tearDown(() => bin.deleteSync(recursive: true));

  Map<String, Object?> run(String event, {String conclusion = 'success'}) => {
    'head_sha': sha,
    'event': event,
    'conclusion': conclusion,
    'html_url': 'https://github.com/o/r/actions/runs/$event',
  };

  Future<ProcessResult> check(List<Map<String, Object?>> runs) => Process.run(
    'bash',
    ['tool/ci_passed.sh', sha],
    environment: {
      'PATH': '${bin.path}:${Platform.environment['PATH']}',
      'GITHUB_REPOSITORY': 'o/r',
      'GH_LOG': '${bin.path}/log',
      'RUNS': jsonEncode({'workflow_runs': runs}),
    },
  );

  group('finds', skip: skip, () {
    test('a push run that passed on the commit', () async {
      final result = await check([run('pull_request'), run('push')]);

      expect(result.exitCode, 0);
      expect(result.stdout, 'https://github.com/o/r/actions/runs/push\n');
      expect(
        File('${bin.path}/log').readAsStringSync(),
        'repos/o/r/actions/workflows/ci.yml/runs?head_sha=$sha&status=success\n',
      );
    });

    test('a manual run that passed on the commit', () async {
      final result = await check([run('workflow_dispatch')]);

      expect(result.exitCode, 0);
      expect(result.stdout, contains('workflow_dispatch'));
    });
  });

  group('finds nothing', skip: skip, () {
    test('without runs', () async {
      final result = await check([]);

      expect(result.exitCode, 1);
      expect(result.stdout, 'No CI run succeeded on $sha.\n');
    });

    test('in a pull_request run, which tested another commit', () async {
      expect((await check([run('pull_request')])).exitCode, 1);
    });

    test('in a run that did not succeed', () async {
      expect((await check([run('push', conclusion: 'failure')])).exitCode, 1);
    });

    test('in a run of another commit', () async {
      expect(
        (await check([
          {...run('push'), 'head_sha': 'another'},
        ])).exitCode,
        1,
      );
    });
  });
}
