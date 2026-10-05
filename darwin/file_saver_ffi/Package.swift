// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "file_saver_ffi",
    platforms: [
        .iOS("13.0"),
        .macOS("10.15.4"),
    ],
    products: [
        .library(name: "file-saver-ffi", targets: ["file_saver_ffi"])
    ],
    targets: [
        // C target providing `FileSaver_PostCObject_DL`. SwiftPM does not allow mixing C and Swift in
        // one target. Names are prefixed (not `DartApiDl`) so they do not clash with other FFI plugins
        // (e.g. dir_picker) that bundle their own Dart API shim in the same package graph.
        .target(
            name: "FileSaverDartApi",
            path: "Sources/FileSaverDartApi",
            publicHeadersPath: "include"
        ),
        .target(
            name: "file_saver_ffi",
            dependencies: ["FileSaverDartApi"],
            path: "Sources/file_saver_ffi",
            // Only used by ffigen (tool/ffigen.dart); the functions are defined via `@_cdecl`.
            exclude: ["FFI/file_saver_ffi.h"]
        ),
    ]
)
