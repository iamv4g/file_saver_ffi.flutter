#!/usr/bin/env bash
# Finds a run of the CI workflow (.github/workflows/ci.yml) that succeeded on
# commit $1, so publish.yml can skip running CI on it again.
#
# Counts only runs that tested that very commit with every job: a push (to
# main or a release/* branch) or a manual run. A pull_request run tests the
# PR merged into its base, a commit that isn't the one on the branch, and only
# the jobs the change needs.
#
# Prints the run's URL and exits 0 if there is one; exits 1 if not. Needs the
# GitHub CLI, with GH_TOKEN and GITHUB_REPOSITORY set.
#
#   GITHUB_REPOSITORY=iamv4g/file_saver_ffi.flutter bash tool/ci_passed.sh <sha>
set -euo pipefail

sha=${1:?Usage: $0 <commit sha>}

url=$(gh api "repos/$GITHUB_REPOSITORY/actions/workflows/ci.yml/runs?head_sha=$sha&status=success" \
  --jq "[.workflow_runs[]
         | select(.head_sha == \"$sha\" and .conclusion == \"success\")
         | select(.event == \"push\" or .event == \"workflow_dispatch\")
        ][0].html_url // empty")

if [ -z "$url" ]; then
  echo "No CI run succeeded on $sha."
  exit 1
fi
echo "$url"
