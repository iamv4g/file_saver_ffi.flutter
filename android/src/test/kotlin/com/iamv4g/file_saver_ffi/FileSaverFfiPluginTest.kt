package com.iamv4g.file_saver_ffi

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Looper
import androidx.activity.ComponentActivity
import androidx.core.app.ActivityCompat
import com.iamv4g.file_saver_ffi.models.ConflictResolution
import com.iamv4g.file_saver_ffi.models.SaveLocation
import com.iamv4g.file_saver_ffi.testing.Event
import com.iamv4g.file_saver_ffi.testing.FakeActivityBinding
import com.iamv4g.file_saver_ffi.testing.FakeEngine
import com.iamv4g.file_saver_ffi.testing.FileSaverTestBase
import com.iamv4g.file_saver_ffi.testing.RecordingCallback
import com.iamv4g.file_saver_ffi.utils.Constants
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.util.concurrent.CopyOnWriteArrayList

/**
 * Drives [FileSaverFfiPlugin] through the embedding's lifecycle callbacks on
 * Android 9, where saving needs WRITE_EXTERNAL_STORAGE. Permission dialogs
 * are intercepted with an [ActivityCompat.PermissionCompatDelegate] and
 * answered by calling `onRequestPermissionsResult`, as Android does.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
class FileSaverFfiPluginTest : FileSaverTestBase() {
    private data class Dialog(
        val activity: Activity,
        val requestCode: Int,
    )

    private val engines = mutableListOf<FakeEngine>()
    private val dialogs = CopyOnWriteArrayList<Dialog>()
    private val requestScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    @Before
    fun interceptPermissionDialogs() {
        shadowOf(context).denyPermissions(WRITE)
        ActivityCompat.setPermissionCompatDelegate(
            object : ActivityCompat.PermissionCompatDelegate {
                override fun requestPermissions(
                    activity: Activity,
                    permissions: Array<out String>,
                    requestCode: Int,
                ): Boolean {
                    dialogs += Dialog(activity, requestCode)
                    return true
                }

                override fun onActivityResult(
                    activity: Activity,
                    requestCode: Int,
                    resultCode: Int,
                    data: Intent?,
                ) = false
            },
        )
    }

    @After
    fun detachEngines() {
        ActivityCompat.setPermissionCompatDelegate(null)
        engines.forEach { it.destroy() }
        requestScope.cancel()
    }

    // ── concurrent requests ────────────────────────────────────────────────

    @Test
    fun `saves that need the permission while the dialog is showing share its answer`() {
        engine().attach(componentActivity())
        val first = startSave("first")
        runMainUntil { dialogs.size == 1 }
        val second = startSave("second")
        idleMain(300)

        answer(dialogs.single(), granted = true)

        assertEquals(3, first.awaitSave().type)
        assertEquals(3, second.awaitSave().type)
        assertEquals(1, dialogs.size)
    }

    @Test
    fun `a request after the dialog was answered shows a new dialog`() {
        engine().attach(componentActivity())
        val denied = request()
        runMainUntil { dialogs.size == 1 }
        answer(dialogs[0], granted = false)
        assertFalse(denied.awaitResult())

        val retried = request()
        runMainUntil { dialogs.size == 2 }
        answer(dialogs[1], granted = true)

        assertTrue(retried.awaitResult())
    }

    // ── activity lifecycle ─────────────────────────────────────────────────

    @Test
    fun `the answer reaches the request after a configuration change while the dialog is showing`() {
        val engine = engine()
        val controller = Robolectric.buildActivity(ComponentActivity::class.java).setup()
        engine.attach(controller.get())
        val result = request()
        runMainUntil { dialogs.size == 1 }

        engine.plugin.onDetachedFromActivityForConfigChanges()
        controller.recreate()
        engine.plugin.onReattachedToActivityForConfigChanges(FakeActivityBinding(controller.get()))
        answer(Dialog(controller.get(), dialogs[0].requestCode), granted = true)

        assertTrue(result.awaitResult())
    }

    @Test
    fun `an answer that arrives before the plugin reattaches after a configuration change is not lost`() {
        val engine = engine()
        val controller = Robolectric.buildActivity(ComponentActivity::class.java).setup()
        engine.attach(controller.get())
        val result = request()
        runMainUntil { dialogs.size == 1 }

        engine.plugin.onDetachedFromActivityForConfigChanges()
        controller.recreate()
        answer(Dialog(controller.get(), dialogs[0].requestCode), granted = true)
        engine.plugin.onReattachedToActivityForConfigChanges(FakeActivityBinding(controller.get()))

        assertTrue(result.awaitResult())
    }

    @Test
    fun `the request is denied when the activity goes away while the dialog is showing`() {
        val engine = engine()
        engine.attach(componentActivity())
        val result = request()
        runMainUntil { dialogs.size == 1 }

        engine.plugin.onDetachedFromActivity()

        assertFalse(result.awaitResult())
    }

    @Test
    fun `an activity that is not a ComponentActivity gets the answer through the result listener`() {
        val engine = engine()
        engine.attach(Robolectric.buildActivity(Activity::class.java).setup().get())
        val result = request()
        runMainUntil { dialogs.size == 1 }

        shadowOf(context).grantPermissions(WRITE)
        engine.activityBinding!!.dispatchRequestPermissionsResult(
            dialogs[0].requestCode,
            arrayOf(WRITE),
            intArrayOf(PackageManager.PERMISSION_GRANTED),
        )

        assertTrue(result.awaitResult())
    }

    @Test
    fun `a save without any activity reports PERMISSION_DENIED`() {
        engine()

        val event = startSave("photo").awaitSave()

        assertEquals(2, event.type)
        assertEquals(Constants.ERROR_PERMISSION_DENIED, event.data)
        assertTrue(event.message!!.contains("no Activity"))
    }

    // ── several engines ────────────────────────────────────────────────────

    @Test
    fun `detaching a second engine keeps saves working for the first`() {
        val mainActivity = componentActivity()
        engine().attach(mainActivity)
        val background = engine()
        background.attach(componentActivity())

        background.destroy()
        assertNotNull(FileSaver.appContext)
        val save = startSave("photo")
        runMainUntil { dialogs.size == 1 }
        assertSame(mainActivity, dialogs[0].activity)
        answer(dialogs[0], granted = true)

        assertEquals(3, save.awaitSave().type)
    }

    @Test
    fun `the dialog is shown in the most recently attached activity`() {
        engine().attach(componentActivity())
        val latest = componentActivity()
        engine().attach(latest)

        val result = request()
        runMainUntil { dialogs.size == 1 }

        assertSame(latest, dialogs[0].activity)
        answer(dialogs[0], granted = true)
        assertTrue(result.awaitResult())
    }

    // ── helpers ────────────────────────────────────────────────────────────

    private fun engine() = FakeEngine(context).also { engines += it }

    private fun componentActivity(): ComponentActivity = Robolectric.buildActivity(ComponentActivity::class.java).setup().get()

    private fun request(): Deferred<Boolean> = requestScope.async { FileSaver.storagePermissionHandler!!.requestStoragePermission() }

    private fun startSave(fileName: String): RecordingCallback =
        RecordingCallback().also {
            fileSaver.saveBytes(
                byteArrayOf(1, 2, 3),
                fileName,
                "png",
                "image/png",
                SaveLocation.PICTURES.ordinal,
                "probe",
                ConflictResolution.AUTO_RENAME.value,
                it,
            )
        }

    /** Answers [dialog] the way Android does once the user taps a button. */
    private fun answer(
        dialog: Dialog,
        granted: Boolean,
    ) {
        if (granted) shadowOf(context).grantPermissions(WRITE) else shadowOf(context).denyPermissions(WRITE)
        val result = if (granted) PackageManager.PERMISSION_GRANTED else PackageManager.PERMISSION_DENIED
        dialog.activity.onRequestPermissionsResult(dialog.requestCode, arrayOf(WRITE), intArrayOf(result))
    }

    /** Waits for the request, running main-looper tasks meanwhile. */
    private fun Deferred<Boolean>.awaitResult(): Boolean {
        runMainUntil { isCompleted }
        return runBlocking { await() }
    }

    /** Waits for the save's terminal event, running main-looper tasks meanwhile. */
    private fun RecordingCallback.awaitSave(): Event {
        runMainUntil { events.any { it.isTerminal } }
        return awaitTerminal()
    }

    /** Runs main-looper tasks (the test runs on the main thread) until [condition] holds. */
    private fun runMainUntil(condition: () -> Boolean) {
        val deadline = System.currentTimeMillis() + 5_000
        while (!condition()) {
            if (System.currentTimeMillis() >= deadline) throw AssertionError("Timed out; dialogs so far: $dialogs")
            idleMain(10)
        }
    }

    private fun idleMain(ms: Long) {
        val deadline = System.currentTimeMillis() + ms
        do {
            shadowOf(Looper.getMainLooper()).idle()
            Thread.sleep(5)
        } while (System.currentTimeMillis() < deadline)
    }

    private companion object {
        const val WRITE = Manifest.permission.WRITE_EXTERNAL_STORAGE
    }
}
