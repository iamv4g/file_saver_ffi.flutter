package com.iamv4g.file_saver_ffi.utils

/**
 * Decides which byte counts of a copy are reported, as the Darwin
 * `ProgressReporter` does: a count is reported when it is the last one or
 * [totalBytes], has grown by at least 1% of [totalBytes] since the last one
 * reported, or has grown and 100 ms have passed. A download of unknown size
 * reports at most every 100 ms.
 *
 * @param totalBytes The size of the file, or null if it isn't known
 * @param nowMs Monotonic clock in milliseconds; tests replace it
 */
internal class ProgressThrottle(
    private val totalBytes: Long?,
    private val nowMs: () -> Long = { System.nanoTime() / 1_000_000 },
) {
    private var lastBytes = 0L
    private var lastTimeMs: Long? = null

    /**
     * Whether to report [bytes], which is then the last count reported.
     *
     * @param isLast True for the count at the end of the copy, which is
     *   reported unless it was already
     */
    fun shouldReport(
        bytes: Long,
        isLast: Boolean = false,
    ): Boolean {
        if (bytes <= lastBytes) return false
        val now = nowMs()
        val lastTime = lastTimeMs
        val report =
            isLast ||
                bytes == totalBytes ||
                lastTime == null ||
                (totalBytes != null && (bytes - lastBytes) * 100 >= totalBytes) ||
                now - lastTime >= MIN_INTERVAL_MS
        if (report) {
            lastBytes = bytes
            lastTimeMs = now
        }
        return report
    }

    companion object {
        const val MIN_INTERVAL_MS = 100L
    }
}
