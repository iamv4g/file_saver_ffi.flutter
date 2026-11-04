#!/usr/bin/env bash
# Decides the `CI result` job of .github/workflows/ci.yml, the required
# status check.
#
# Reads the job's `needs` context as JSON on stdin, prints the result of each
# job, and fails unless every job succeeded. A platform job may also be
# skipped, but only when the change doesn't need it (the outputs of the
# `changes` job). Any other result fails, whatever GitHub calls it: a job
# that never got a runner, for one, is `abandoned`, not `cancelled`.
#
# Try it locally:
#   echo '{"changes":{"result":"success","outputs":{...}}, ...}' | bash tool/ci_result.sh
set -euo pipefail

needs=$(cat)

jq -r 'to_entries[] | "\(.key): \(.value.result)"' <<<"$needs"

failed=$(jq -r '
  (.changes.outputs // {}) as $scope
  # The jobs that run only when the change needs them, and whether it does.
  | {
      "android-unit-test": ($scope.android == "true"),
      "darwin-unit-test": ($scope.darwin == "true"),
      "web-test": ($scope.web == "true"),
      "build": (($scope.build // "[]") != "[]")
    } as $needed
  | to_entries[]
  | .key as $job
  | .value.result as $result
  | select($result != "success")
  | select($result != "skipped" or (if $needed | has($job) then $needed[$job] else true end))
  | "\($job) (\($result))"
' <<<"$needs")

if [ -n "$failed" ]; then
  echo "::error::Jobs that didn't succeed: $(paste -sd, - <<<"$failed" | sed 's/,/, /g')"
  exit 1
fi
