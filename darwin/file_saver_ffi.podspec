#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint file_saver_ffi.podspec` to validate before publishing.
#
require 'yaml'

# The package version, so the pod never reports a stale one.
pubspec = YAML.load_file(File.join(__dir__, '..', 'pubspec.yaml'))

Pod::Spec.new do |s|
  s.name             = 'file_saver_ffi'
  s.version          = pubspec['version']
  s.summary          = 'FFI-based file saver for iOS and macOS'
  s.description      = <<-DESC
A Flutter plugin for saving files to device storage using FFI. Supports iOS and macOS.
                       DESC
  s.homepage         = 'https://github.com/iamv4g/file_saver_ffi.flutter'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'iamv4g' => 'iamv4g.dev@gmail.com' }

  # This will ensure the source files in Classes/ are included in the native
  # builds of apps using this FFI plugin.
  s.source           = { :path => '.' }
  s.source_files = 'file_saver_ffi/Sources/**/*.{h,c,swift}'
  # Only used by ffigen (tool/ffigen.dart); the functions are defined via
  # `@_cdecl`. Package.swift excludes it too.
  s.exclude_files = 'file_saver_ffi/Sources/file_saver_ffi/FFI/file_saver_ffi.h'
  s.public_header_files = 'file_saver_ffi/Sources/FileSaverDartApi/include/*.h'
  # Package.swift ships the same manifest, as a resource of its Swift target.
  s.resource_bundles = {
    'file_saver_ffi_privacy' => ['file_saver_ffi/Sources/file_saver_ffi/Resources/PrivacyInfo.xcprivacy']
  }

  # Platform-specific dependencies
  s.ios.dependency 'Flutter'
  s.osx.dependency 'FlutterMacOS'

  # Platform-specific deployment targets
  # The minimums of Flutter 3.47, the lowest Flutter the package supports.
  s.ios.deployment_target = '15.0'
  s.osx.deployment_target = '12.0'

  # Preserve the module map for FileSaverDartApi module
  s.preserve_paths = 'file_saver_ffi/Sources/FileSaverDartApi/include/module.modulemap'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'SWIFT_INCLUDE_PATHS' => '$(PODS_TARGET_SRCROOT)/file_saver_ffi/Sources/FileSaverDartApi/include',
    'OTHER_CFLAGS' => '-I$(PODS_TARGET_SRCROOT)/file_saver_ffi/Sources/FileSaverDartApi/include'
  }
  # The Swift language mode (SWIFT_VERSION takes 4.0, 4.2, 5.0 or 6.0), the
  # one Package.swift compiles in too: its swift-tools-version 5.9 is the
  # manifest format, and leaves the mode at Swift 5.
  s.swift_version = '5.0'
end
