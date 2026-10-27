## Description

<!-- What does this PR change, and why? Link the issue it resolves, e.g. "Fixes #123". -->

Fixes #

## Type of change

<!-- Check all that apply. The PR title should follow Conventional Commits with a platform scope,
     e.g. `feat(darwin): …`, `fix(android): …`, `refactor(web): …`, `docs: …`. -->

- [ ] 🐛 Bug fix (non-breaking change that fixes an issue)
- [ ] ✨ New feature (non-breaking change that adds functionality)
- [ ] 💥 Breaking change (public API, behaviour or minimum platform/SDK version changes)
- [ ] ♻️ Refactor / performance (no behaviour change)
- [ ] 📝 Documentation
- [ ] 🔧 Build / CI / tooling

## Affected platforms

- [ ] Android
- [ ] iOS
- [ ] macOS
- [ ] Windows
- [ ] Linux
- [ ] Web
- [ ] Dart layer only (shared / platform interface)

## How was this tested?

<!-- Devices, OS versions and browsers you ran the example app on, and which flows you exercised
     (bytes / file / network, saveAs, openWrite, cancel, conflict resolution…). -->

| Platform | Device / OS / browser | Result |
| -------- | --------------------- | ------ |
|          |                       |        |

## Checklist

- [ ] `flutter analyze` reports no issues
- [ ] `dart format lib tool` applied (Swift follows `darwin/.swift-format`, Kotlin follows ktlint)
- [ ] Tested in the `example/` app on every platform checked above
- [ ] `CHANGELOG.md` updated for user-facing changes
- [ ] README / `WEB_LIMITATIONS.md` updated if behaviour or setup changed

<details>
<summary><b>Native bridge / cross-language changes</b> (check if relevant)</summary>

- [ ] Generated bindings were regenerated, not hand-edited (`dart run tool/ffigen.dart` / `dart run tool/jnigen.dart`)
- [ ] New Darwin functions are in the C header, the Swift `@_cdecl`, and `Functions.include` in `tool/ffigen.dart`
- [ ] Enum order still matches across Dart / Kotlin / Swift (`ConflictResolution`, `SaveLocation`)
- [ ] Progress event codes (0–4) and error codes still map to the Dart exceptions
- [ ] Both SwiftPM (`Package.swift`) and CocoaPods (`file_saver_ffi.podspec`) still build
- [ ] Web/IO stubs (`io_stub.dart`, `web_stub.dart`) updated for new/renamed platform classes or interface methods

</details>

## Screenshots / recordings

<!-- Optional: helpful for permission prompts, pickers or gallery results. -->
