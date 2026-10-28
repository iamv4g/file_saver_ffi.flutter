package com.vanvixi.file_saver_ffi.testing

import com.vanvixi.file_saver_ffi.models.ProgressCallback
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.TimeUnit
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/** One [ProgressCallback.onEvent] call. */
data class Event(
    val type: Int,
    val progress: Double,
    val data: String?,
    val message: String?,
) {
    val isTerminal get() = type == 2 || type == 3 || type == 4
}

/**
 * [ProgressCallback] that records every event, standing in for the Dart side
 * of the JNI bridge. Events arrive on background threads.
 *
 * @param onEvent Runs before the event is recorded, e.g. to throw or block.
 */
class RecordingCallback(
    private val onEvent: (Event) -> Unit = {},
) : ProgressCallback {
    val events = CopyOnWriteArrayList<Event>()
    private val lock = ReentrantLock()
    private val changed = lock.newCondition()

    override fun onEvent(
        eventType: Int,
        progress: Double,
        data: String?,
        message: String?,
    ) {
        val event = Event(eventType, progress, data, message)
        onEvent(event)
        lock.withLock {
            events += event
            changed.signalAll()
        }
    }

    /** Waits until [count] events have arrived and returns the last one. */
    fun awaitEvents(
        count: Int,
        timeoutMs: Long = 5_000,
    ): Event = awaitMatching(timeoutMs) { events.size >= count }.let { events[count - 1] }

    /** Waits for the first terminal event (error, success or cancelled). */
    fun awaitTerminal(timeoutMs: Long = 5_000): Event =
        awaitMatching(timeoutMs) { events.any { it.isTerminal } }.let { events.first { it.isTerminal } }

    private fun awaitMatching(
        timeoutMs: Long,
        condition: () -> Boolean,
    ) {
        val deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(timeoutMs)
        lock.withLock {
            while (!condition()) {
                val remaining = deadline - System.nanoTime()
                if (remaining <= 0) throw AssertionError("Timed out after ${timeoutMs}ms; events so far: $events")
                changed.awaitNanos(remaining)
            }
        }
    }
}
