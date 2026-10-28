#!/usr/bin/env bash
# Decides which CI jobs a change needs.
#
# Reads the changed file paths on stdin, one per line, and prints lines for
# $GITHUB_OUTPUT:
#   android|darwin|windows|linux|web|desktop=true|false
#   test=<JSON matrix include list for the Test job>
#   build=<JSON matrix include list for the Build example job>
# A path it doesn't know runs everything. With --all, everything runs.
#
# Try it locally:
#   git diff --name-only origin/main... | bash tool/ci_changes.sh
set -euo pipefail

all=false android=false darwin=false windows=false linux=false web=false
# Shared dart:io code (PathLocation, conflict resolution, desktop saver),
# which the Test job also runs on macOS and Windows file systems.
desktop=false
[ "${1:-}" = --all ] && all=true

if ! $all; then
  while IFS= read -r path; do
    case "$path" in
      '') ;;
      # Covered by the Analyze job (publish dry run), which always runs.
      *.md | LICENSE | .gitignore | screenshots/* | .github/ISSUE_TEMPLATE/* | .github/pull_request_template.md) ;;
      test/platforms/windows/*) windows=true ;;
      test/platforms/shared/* | test/helpers/*) desktop=true ;;
      # The rest of test/ (contracts, exceptions, facade) runs on Ubuntu, always.
      test/*) ;;
      android/* | lib/src/platforms/android/* | example/android/* | tool/jnigen.dart) android=true ;;
      darwin/* | lib/src/platforms/darwin/* | example/ios/* | example/macos/* | tool/ffigen.dart) darwin=true ;;
      lib/src/platforms/windows/* | example/windows/*) windows=true ;;
      lib/src/platforms/linux/* | example/linux/*) linux=true ;;
      lib/src/platforms/shared/*) desktop=true windows=true linux=true ;;
      lib/src/platforms/web/* | example/web/*) web=true ;;
      # The facade, models, conditional exports, pubspec, the example app,
      # CI itself and anything new.
      *) all=true ;;
    esac
  done
fi

if $all; then
  android=true darwin=true windows=true linux=true web=true desktop=true
fi

# Ubuntu always runs the Dart tests, on stable and on the minimum Flutter
# version from pubspec.yaml `environment.flutter`.
tests=('{"os":"ubuntu-latest","flutter":"stable"}' '{"os":"ubuntu-latest","flutter":"3.44.0"}')
$desktop && tests+=('{"os":"macos-latest","flutter":"stable"}')
{ $desktop || $windows; } && tests+=('{"os":"windows-latest","flutter":"stable"}')

builds=()
$android && builds+=('{"os":"ubuntu-latest","target":"apk"}')
$linux && builds+=('{"os":"ubuntu-latest","target":"linux"}')
$web && builds+=('{"os":"ubuntu-latest","target":"web"}')
$windows && builds+=('{"os":"windows-latest","target":"windows"}')
# The plugin ships both Package.swift and a podspec; build both.
$darwin && builds+=('{"os":"macos-latest","target":"macos"}' '{"os":"macos-latest","target":"ios","ios-deps":"swiftpm"}' '{"os":"macos-latest","target":"ios","ios-deps":"cocoapods"}')

echo "android=$android"
echo "darwin=$darwin"
echo "windows=$windows"
echo "linux=$linux"
echo "web=$web"
echo "desktop=$desktop"
echo "test=[$(IFS=,; echo "${tests[*]}")]"
echo "build=[$(IFS=,; echo "${builds[*]:-}")]"
