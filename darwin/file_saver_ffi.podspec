#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint file_saver_ffi.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'file_saver_ffi'
  s.version          = '0.0.1'
  s.summary          = 'FFI-based file saver for iOS and macOS'
  s.description      = <<-DESC
A Flutter plugin for saving files to device storage using FFI. Supports iOS and macOS.
                       DESC
  s.homepage         = 'https://github.com/vanvixi/file_saver_ffi.flutter'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Vanvixi' => 'vanvixi.dev@gmail.com' }

  # This will ensure the source files in Classes/ are included in the native
  # builds of apps using this FFI plugin.
  s.source           = { :path => '.' }
  s.source_files = 'file_saver_ffi/Sources/**/*.{h,c,swift}'
  s.public_header_files = 'file_saver_ffi/Sources/FileSaverDartApi/include/*.h'

  # Platform-specific dependencies
  s.ios.dependency 'Flutter'
  s.osx.dependency 'FlutterMacOS'

  # Platform-specific deployment targets
  s.ios.deployment_target = '13.0'
  s.osx.deployment_target = '10.15.4'

  # Preserve the module map for FileSaverDartApi module
  s.preserve_paths = 'file_saver_ffi/Sources/FileSaverDartApi/include/module.modulemap'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
    'SWIFT_INCLUDE_PATHS' => '$(PODS_TARGET_SRCROOT)/file_saver_ffi/Sources/FileSaverDartApi/include',
    'OTHER_CFLAGS' => '-I$(PODS_TARGET_SRCROOT)/file_saver_ffi/Sources/FileSaverDartApi/include'
  }
  s.swift_version = '5.0'
end
