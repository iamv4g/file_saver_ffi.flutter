package com.iamv4g.file_saver_ffi.models

// SaveLocation itself is generated from the Dart AndroidSaveLocation, in
// Contracts.g.kt. Each value is a MediaStore collection or public directory:
// Pictures/, Movies/, Music/, Download/ and DCIM/.

/** The [SaveLocation] Dart sent as [value], or DOWNLOADS for an unknown one. */
fun SaveLocation.Companion.fromInt(value: Int): SaveLocation = fromIndex(value) ?: SaveLocation.DOWNLOADS
