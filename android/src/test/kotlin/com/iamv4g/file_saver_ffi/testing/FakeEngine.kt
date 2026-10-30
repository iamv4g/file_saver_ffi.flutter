package com.iamv4g.file_saver_ffi.testing

import android.app.Activity
import android.content.Context
import com.iamv4g.file_saver_ffi.FileSaverFfiPlugin
import java.util.concurrent.atomic.AtomicLong

/**
 * A Flutter engine as [FileSaverFfiPlugin] sees it: an instance attached with
 * engine [id]. Detaching goes through the real embedding callbacks, but
 * attaching uses [FileSaverFfiPlugin.attachEngine], because a binding can't
 * provide a `FlutterEngine` without the native engine.
 */
class FakeEngine(
    private val context: Context,
    val id: Long = nextId.incrementAndGet(),
) {
    val plugin = FileSaverFfiPlugin().apply { attachEngine(context, id) }
    var activityBinding: FakeActivityBinding? = null
        private set

    fun attach(activity: Activity) {
        activityBinding = FakeActivityBinding(activity).also { plugin.onAttachedToActivity(it) }
    }

    /** Detaches the Activity, if any, and the engine, as the embedding does when the engine is destroyed. */
    fun destroy() {
        plugin.onDetachedFromActivity()
        plugin.onDetachedFromEngine(flutterPluginBinding(context))
    }

    private companion object {
        val nextId = AtomicLong(100)
    }
}
