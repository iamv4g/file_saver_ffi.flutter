package com.iamv4g.file_saver_ffi.utils

import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * Lets one save at a time pick a name in a directory and create its entry
 * there, or give its entry the name it replaces.
 *
 * Picking a free name and creating the entry are separate calls (a MediaStore
 * query and an insert, a directory listing and a create), so concurrent saves
 * of one name would otherwise all pick the same name. Hold the lock only for
 * those steps, never while the content is written.
 *
 * Directories share a fixed set of mutexes by hash, so two directories may use
 * the same one, which only makes their saves wait for each other.
 */
internal object DirectoryLock {
    val mutexes = Array(64) { Mutex() }

    /** Runs [block] holding the lock of [directory], which is compared ignoring case. */
    suspend inline fun <T> withLock(
        directory: String,
        block: () -> T,
    ): T = mutexes[Math.floorMod(directory.lowercase().hashCode(), mutexes.size)].withLock(action = block)
}
