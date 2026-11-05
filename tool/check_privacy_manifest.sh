#!/usr/bin/env bash
# Checks that a built iOS or macOS app bundles the plugin's privacy manifest,
# darwin/file_saver_ffi/Sources/file_saver_ffi/Resources/PrivacyInfo.xcprivacy,
# as App Store Connect requires of an SDK that uses a required reason API.
#
#   bash tool/check_privacy_manifest.sh example/build/ios/iphoneos/Runner.app
#
# CocoaPods puts it in file_saver_ffi_privacy.bundle (the podspec's
# resource_bundles), SwiftPM in file_saver_ffi_file_saver_ffi.bundle (the
# Package.swift resources).
set -euo pipefail

if [ $# -ne 1 ] || [ ! -d "$1" ]; then
  echo "Usage: $0 <path to the built .app>" >&2
  exit 2
fi
app=$1
source=$(cd "$(dirname "$0")/.." && pwd)/darwin/file_saver_ffi/Sources/file_saver_ffi/Resources/PrivacyInfo.xcprivacy

found=$(find "$app" -path '*file_saver_ffi*.bundle/*' -name PrivacyInfo.xcprivacy)
if [ -z "$found" ]; then
  echo "::error::$app has no file_saver_ffi bundle with a PrivacyInfo.xcprivacy."
  exit 1
fi

# The build may store the plist in another format, so compare the contents.
want=$(plutil -convert json -o - "$source")
while IFS= read -r manifest; do
  if [ "$(plutil -convert json -o - "$manifest")" != "$want" ]; then
    echo "::error::$manifest differs from $source."
    exit 1
  fi
  echo "${manifest#"$app"/} is the plugin's privacy manifest."
done <<<"$found"
