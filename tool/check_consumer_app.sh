#!/usr/bin/env bash
# Builds a new Flutter app that depends on the plugin, and checks that its APK
# has the plugin's Kotlin classes.
#
# The example app turns AGP 9's built-in Kotlin on, but apps made by
# `flutter create` leave it off, and older apps are still on AGP 8. In both,
# Flutter compiles the plugin's Kotlin with the Kotlin Gradle Plugin, which the
# plugin doesn't apply itself. This checks that it still does.
#
#   bash tool/check_consumer_app.sh
#       The app as `flutter create` makes it.
#   bash tool/check_consumer_app.sh <agp> <gradle> <kotlin>
#       The app moved to that Android Gradle Plugin, Gradle and Kotlin Gradle
#       Plugin, e.g. 8.11.1 8.14.3 2.3.20. Flutter keeps
#       `android.builtInKotlin=false` in its gradle.properties (its migrator
#       adds it back), which AGP 8 doesn't know and ignores.
#
# The app goes in a new temporary directory.
set -euo pipefail

plugin=$(cd "$(dirname "$0")/.." && pwd)
app=$(mktemp -d)/consumer
echo "Creating $app"
flutter create --platforms android --project-name consumer "$app" >/dev/null
cd "$app"

# Replaces $2 with $3 in file $1, and fails if $2 isn't there (the template
# changed).
replace() {
  grep -qF -- "$2" "$1" || { echo "::error::$1 has no '$2'"; exit 1; }
  OLD=$2 NEW=$3 perl -pi -e 's/\Q$ENV{OLD}\E/$ENV{NEW}/g' "$1"
}

if [ $# -eq 3 ]; then
  agp=$1 gradle=$2 kotlin=$3
  settings=android/settings.gradle.kts
  version_of() { sed -n "s/.*id(\"$1\") version \"\([^\"]*\)\".*/\1/p" "$settings"; }
  replace "$settings" "id(\"com.android.application\") version \"$(version_of com.android.application)\"" \
    "id(\"com.android.application\") version \"$agp\""
  replace "$settings" "id(\"org.jetbrains.kotlin.android\") version \"$(version_of org.jetbrains.kotlin.android)\"" \
    "id(\"org.jetbrains.kotlin.android\") version \"$kotlin\""
  wrapper=android/gradle/wrapper/gradle-wrapper.properties
  replace "$wrapper" "$(grep -o 'gradle-[0-9.]*-all.zip' "$wrapper")" "gradle-$gradle-all.zip"
elif [ $# -ne 0 ]; then
  echo "Usage: $0 [<agp> <gradle> <kotlin>]" >&2
  exit 2
fi

grep -E 'com.android.application|org.jetbrains.kotlin.android' android/settings.gradle.kts
grep -o 'gradle-[0-9.]*-all.zip' android/gradle/wrapper/gradle-wrapper.properties

flutter pub add file_saver_ffi --path "$plugin" >/dev/null
cat >lib/main.dart <<'EOF'
import 'package:file_saver_ffi/file_saver_ffi.dart';
import 'package:flutter/widgets.dart';

void main() => debugPrint('${FileSaver.saveAsync}');
EOF

flutter build apk --debug
# The flags as Flutter left them.
grep '^android\.' android/gradle.properties || true

# A build that skipped the plugin's Kotlin would still succeed, and the app
# would fail only when the JNI bindings look up FileSaver.
apk=build/app/outputs/flutter-apk/app-debug.apk
# (grep -c, not -q: -q stops reading early, and pipefail then fails on unzip's
# SIGPIPE.)
found=$(unzip -p "$apk" 'classes*.dex' | LC_ALL=C grep -ac 'Lcom/iamv4g/file_saver_ffi/FileSaver;' || true)
if [ "$found" -gt 0 ]; then
  echo "The APK has com.iamv4g.file_saver_ffi.FileSaver."
else
  echo "::error::The APK has no com.iamv4g.file_saver_ffi.FileSaver: the plugin's Kotlin wasn't compiled."
  exit 1
fi
