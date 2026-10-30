package com.iamv4g.file_saver_ffi.testing

import android.app.Activity
import android.content.Context
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.PluginRegistry
import java.util.concurrent.CopyOnWriteArrayList

/**
 * A [FlutterPlugin.FlutterPluginBinding] for an engine that only provides
 * [context]. The constructor's other arguments are `@NonNull`, which Kotlin
 * won't pass null to, hence the reflection.
 */
fun flutterPluginBinding(context: Context): FlutterPlugin.FlutterPluginBinding =
    FlutterPlugin.FlutterPluginBinding::class.java.constructors
        .single()
        .newInstance(context, null, null, null, null, null, null) as FlutterPlugin.FlutterPluginBinding

/**
 * [ActivityPluginBinding] for [activity] that records permission-result
 * listeners, like the embedding's binding does for a FlutterActivity.
 */
class FakeActivityBinding(
    private val activity: Activity,
) : ActivityPluginBinding {
    private val permissionListeners = CopyOnWriteArrayList<PluginRegistry.RequestPermissionsResultListener>()

    /** Forwards a permission result to the listeners, as FlutterActivity does. */
    fun dispatchRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<String>,
        grantResults: IntArray,
    ) {
        permissionListeners.forEach { it.onRequestPermissionsResult(requestCode, permissions, grantResults) }
    }

    override fun getActivity(): Activity = activity

    override fun getLifecycle(): Any = throw UnsupportedOperationException()

    override fun addRequestPermissionsResultListener(listener: PluginRegistry.RequestPermissionsResultListener) {
        permissionListeners += listener
    }

    override fun removeRequestPermissionsResultListener(listener: PluginRegistry.RequestPermissionsResultListener) {
        permissionListeners -= listener
    }

    override fun addActivityResultListener(listener: PluginRegistry.ActivityResultListener) {}

    override fun removeActivityResultListener(listener: PluginRegistry.ActivityResultListener) {}

    override fun addOnNewIntentListener(listener: PluginRegistry.NewIntentListener) {}

    override fun removeOnNewIntentListener(listener: PluginRegistry.NewIntentListener) {}

    override fun addOnUserLeaveHintListener(listener: PluginRegistry.UserLeaveHintListener) {}

    override fun removeOnUserLeaveHintListener(listener: PluginRegistry.UserLeaveHintListener) {}

    override fun addOnWindowFocusChangedListener(listener: PluginRegistry.WindowFocusChangedListener) {}

    override fun removeOnWindowFocusChangedListener(listener: PluginRegistry.WindowFocusChangedListener) {}

    override fun addOnSaveStateListener(listener: ActivityPluginBinding.OnSaveInstanceStateListener) {}

    override fun removeOnSaveStateListener(listener: ActivityPluginBinding.OnSaveInstanceStateListener) {}
}
