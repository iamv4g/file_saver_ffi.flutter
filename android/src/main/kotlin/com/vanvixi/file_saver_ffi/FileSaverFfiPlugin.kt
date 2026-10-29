package com.vanvixi.file_saver_ffi

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.vanvixi.file_saver_ffi.utils.StoragePermissionHandler
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.PluginRegistry.RequestPermissionsResultListener
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext
import java.util.concurrent.atomic.AtomicInteger

/**
 * Flutter plugin for file_saver_ffi.
 *
 * Handles:
 * - WRITE_EXTERNAL_STORAGE runtime permission for Android 9 and below
 *
 * Directory picking is handled by the dir_picker package.
 *
 * Every engine in the process (add-to-app, background engines) gets its own
 * instance, while [FileSaver] state is static. So an instance never clears
 * state another engine still uses, and the permission dialog is shown by
 * whichever engine has an Activity.
 */
class FileSaverFfiPlugin :
    FlutterPlugin,
    ActivityAware,
    RequestPermissionsResultListener {
    companion object {
        private const val TAG = "FileSaverFfi"
        private const val REQUEST_CODE_STORAGE_PERMISSION = 43892

        // Prefix of the ActivityResultRegistry key. Each instance appends its
        // own id, so two engines in one Activity don't replace each other.
        private const val PERMISSION_REGISTRY_KEY = "com.vanvixi.file_saver_ffi.storage_perm"

        private val nextInstanceId = AtomicInteger()

        // The state below is shared by all instances and guarded by [hosts].

        /** Instances whose engine has an Activity, most recently attached last. */
        private val hosts = mutableListOf<FileSaverFfiPlugin>()

        /** The answer of the dialog being shown, awaited by every save that needs it. */
        private var pendingRequest: CompletableDeferred<Boolean>? = null

        /** The instance whose Activity shows the dialog of [pendingRequest]. */
        private var pendingHost: FileSaverFfiPlugin? = null

        private val permissionHandler = StoragePermissionHandler { requestStoragePermission() }

        /**
         * The [FileSaver]s created by the Dart side of each attached engine, by
         * engine id. Guarded by itself.
         */
        private val saversByEngine = HashMap<Long, MutableList<FileSaver>>()

        /**
         * Ties [saver] to the engine with [engineId], so it is disposed when that
         * engine is destroyed. Does nothing for an id that isn't attached, such
         * as -1 from a background isolate.
         */
        internal fun trackSaver(
            saver: FileSaver,
            engineId: Long,
        ) {
            synchronized(saversByEngine) { saversByEngine[engineId]?.add(saver) }
        }

        /**
         * Asks for WRITE_EXTERNAL_STORAGE in the most recently attached Activity
         * and waits for the answer. A save that needs the permission while the
         * dialog is showing waits for the same answer instead of opening a
         * second dialog.
         *
         * @throws SecurityException if no engine has an Activity to ask in
         */
        private suspend fun requestStoragePermission(): Boolean {
            // Might have been granted since FileSaver checked
            val context = FileSaver.appContext
            if (context != null &&
                ContextCompat.checkSelfPermission(context, Manifest.permission.WRITE_EXTERNAL_STORAGE) ==
                PackageManager.PERMISSION_GRANTED
            ) {
                return true
            }

            var host: FileSaverFfiPlugin? = null
            val request =
                synchronized(hosts) {
                    pendingRequest ?: CompletableDeferred<Boolean>().also {
                        host = hosts.lastOrNull()
                            ?: throw SecurityException("Storage permission required but no Activity available to request it")
                        pendingRequest = it
                        pendingHost = host
                    }
                }
            // The dialog must be launched on the Main thread. It is launched even
            // if this save is cancelled meanwhile, because others may be waiting.
            host?.let { withContext(NonCancellable + Dispatchers.Main) { it.launchPermissionRequest(request) } }
            return request.await()
        }

        /**
         * Completes the pending request with [granted] if [host] shows it (and,
         * when given, if it is still [request]).
         */
        private fun finishPermissionRequest(
            host: FileSaverFfiPlugin,
            granted: Boolean,
            request: CompletableDeferred<Boolean>? = null,
        ) {
            val finished =
                synchronized(hosts) {
                    if (pendingHost !== host || (request != null && pendingRequest !== request)) return
                    pendingRequest.also {
                        pendingRequest = null
                        pendingHost = null
                    }
                }
            finished?.complete(granted)
        }
    }

    private val permissionRegistryKey = "$PERMISSION_REGISTRY_KEY.${nextInstanceId.incrementAndGet()}"

    private var engineId: Long? = null

    private var activity: Activity? = null
    private var activityBinding: ActivityPluginBinding? = null

    // Storage permission handling
    private var permissionLauncher: ActivityResultLauncher<String>? = null

    // ─────────────────────────────────────────────────────────────────────────
    // FlutterPlugin
    // ─────────────────────────────────────────────────────────────────────────

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) =
        attachEngine(binding.applicationContext, binding.flutterEngine.engineId)

    /** [onAttachedToEngine] for an engine with [engineId] (separate for tests). */
    internal fun attachEngine(
        applicationContext: Context,
        engineId: Long,
    ) {
        this.engineId = engineId
        FileSaver.appContext = applicationContext
        FileSaver.storagePermissionHandler = permissionHandler
        synchronized(saversByEngine) { saversByEngine.getOrPut(engineId) { mutableListOf() } }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        // FileSaver.appContext stays set: it is the application context, which
        // lives as long as the process, and other engines may still save.
        detachActivity(changingConfigurations = false)

        // The engine's Dart side is gone, so its saves have no one to report to.
        val savers = engineId?.let { id -> synchronized(saversByEngine) { saversByEngine.remove(id) } }
        engineId = null
        savers?.forEach { it.dispose() }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // ActivityAware
    // ─────────────────────────────────────────────────────────────────────────

    override fun onAttachedToActivity(binding: ActivityPluginBinding) = attachActivity(binding)

    override fun onDetachedFromActivityForConfigChanges() = detachActivity(changingConfigurations = true)

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = attachActivity(binding)

    override fun onDetachedFromActivity() = detachActivity(changingConfigurations = false)

    private fun attachActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        activityBinding = binding
        binding.addRequestPermissionsResultListener(this)
        setupPermissionLauncher(binding.activity)
        synchronized(hosts) {
            hosts.remove(this)
            hosts.add(this)
        }
    }

    private fun detachActivity(changingConfigurations: Boolean) {
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding = null
        activity = null

        permissionLauncher?.unregister()
        permissionLauncher = null

        synchronized(hosts) { hosts.remove(this) }
        // After a configuration change the dialog's answer goes to the recreated
        // Activity, where the launcher is registered again under the same key.
        if (!changingConfigurations) finishPermissionRequest(this, false)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Storage Permission (Android 9 and below)
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Sets up ActivityResultLauncher for WRITE_EXTERNAL_STORAGE permission request.
     * Only registers on ComponentActivity (AndroidX). Registering after a
     * configuration change delivers an answer that arrived in between.
     */
    private fun setupPermissionLauncher(activity: Activity) {
        if (activity !is ComponentActivity) return

        permissionLauncher =
            activity.activityResultRegistry.register(
                permissionRegistryKey,
                ActivityResultContracts.RequestPermission(),
            ) { isGranted: Boolean ->
                finishPermissionRequest(this, isGranted)
            }
    }

    /** Shows the permission dialog for [request]. Runs on the Main thread. */
    private fun launchPermissionRequest(request: CompletableDeferred<Boolean>) {
        // Try modern launcher first (ComponentActivity)
        val launcher = permissionLauncher
        if (launcher != null) {
            try {
                launcher.launch(Manifest.permission.WRITE_EXTERNAL_STORAGE)
                return
            } catch (e: Exception) {
                Log.w(TAG, "Permission launcher failed, falling back: ${e.message}")
            }
        }

        // Fallback: ActivityCompat for non-ComponentActivity
        val act = activity
        if (act != null) {
            ActivityCompat.requestPermissions(
                act,
                arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE),
                REQUEST_CODE_STORAGE_PERMISSION,
            )
        } else {
            finishPermissionRequest(this, false, request)
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // RequestPermissionsResultListener (fallback for non-ComponentActivity)
    // ─────────────────────────────────────────────────────────────────────────

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != REQUEST_CODE_STORAGE_PERMISSION) return false

        val granted =
            grantResults.isNotEmpty() &&
                grantResults[0] == PackageManager.PERMISSION_GRANTED
        finishPermissionRequest(this, granted)
        return true
    }
}
