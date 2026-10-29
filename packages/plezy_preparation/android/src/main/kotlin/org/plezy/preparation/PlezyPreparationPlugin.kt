package org.plezy.preparation

import android.content.Context
import android.app.Activity
import android.app.Application
import android.os.Bundle
import java.util.Collections
import java.util.IdentityHashMap
import androidx.work.*
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.*
import java.util.concurrent.TimeUnit

class PlezyPreparationPlugin : FlutterPlugin {
    private var channel: MethodChannel? = null
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val context = binding.applicationContext
        SubtitleActivity.install(context.applicationContext as Application)
        channel = MethodChannel(binding.binaryMessenger, "org.plezy/preparation").also { ch ->
            ch.setMethodCallHandler { call, result ->
                val subtitles = call.argument<Boolean>("subtitles") == true
                val name = if (subtitles) SUBTITLE_NAME else NAME
                when (call.method) {
                    "schedule" -> {
                        val constraints = Constraints.Builder().setRequiredNetworkType(
                            if (subtitles) NetworkType.NOT_REQUIRED else NetworkType.CONNECTED)
                            .setRequiresBatteryNotLow(true).build()
                        val data = workDataOf("subtitles" to subtitles)
                        val work = OneTimeWorkRequestBuilder<PreparationWorker>().setConstraints(constraints).setInputData(data)
                            .setInitialDelay(30, TimeUnit.SECONDS)
                            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS).build()
                        WorkManager.getInstance(context).enqueueUniqueWork(name, ExistingWorkPolicy.KEEP, work)
                        // Periodic safety net survives process death and a missed enqueue.
                        val periodic = PeriodicWorkRequestBuilder<PreparationWorker>(15, TimeUnit.MINUTES)
                            .setConstraints(constraints).setInputData(data).build()
                        WorkManager.getInstance(context).enqueueUniquePeriodicWork("$name.periodic", ExistingPeriodicWorkPolicy.KEEP, periodic)
                        result.success(null)
                    }
                    "cancel" -> {
                        WorkManager.getInstance(context).cancelUniqueWork(name)
                        WorkManager.getInstance(context).cancelUniqueWork("$name.periodic")
                        result.success(null)
                    }
                    "subtitlesMayRun" -> result.success(!SubtitleActivity.foreground)
                    else -> result.notImplemented()
                }
            }
        }
    }
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
    }
    companion object {
        const val NAME = "org.plezy.preparation"
        const val SUBTITLE_NAME = "org.plezy.subtitle.jobs"
    }
}

class PreparationWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        var engine: FlutterEngine? = null
        var workerChannel: MethodChannel? = null
        val subtitles = inputData.getBoolean("subtitles", false)
        val completed = CompletableDeferred<Boolean>()
        return try {
            withContext(Dispatchers.Main) {
                val loader = FlutterInjector.instance().flutterLoader()
                loader.startInitialization(applicationContext)
                loader.ensureInitializationComplete(applicationContext, null)
                // Auto-register the actual app plugins, including secure storage,
                // path_provider and preferences, in the isolated headless engine.
                val worker = FlutterEngine(applicationContext)
                engine = worker
                val channel = MethodChannel(worker.dartExecutor.binaryMessenger,
                    if (subtitles) "org.plezy/subtitle.worker" else "org.plezy/preparation.worker")
                workerChannel = channel
                channel.setMethodCallHandler { call, result ->
                    when (call.method) {
                        "complete" -> { completed.complete(call.arguments == true); result.success(null) }
                        else -> result.notImplemented()
                    }
                }
                worker.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint(loader.findAppBundlePath(),
                    if (subtitles) "package:plezy/services/subtitle_background_worker.dart"
                    else "package:plezy/services/remote_streams/remote_preparation_worker.dart",
                    if (subtitles) "subtitleBackgroundEntrypoint" else "remotePreparationEntrypoint"))
            }
            if (withTimeout(8 * 60 * 1000L) { completed.await() }) Result.success() else Result.retry()
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            Result.retry()
        } finally {
            withContext(NonCancellable + Dispatchers.Main) {
                if (subtitles && !completed.isCompleted) {
                    workerChannel?.invokeMethod("stop", null)
                    // Native Whisper cancellation is cooperative. Keep the engine
                    // alive briefly to let it drop the window and release ownership.
                    withTimeoutOrNull(15_000L) { completed.await() }
                }
                workerChannel?.setMethodCallHandler(null)
                engine?.destroy()
            }
        }
    }
}

// Engine-local Flutter lifecycle does not describe another engine's activity.
// Track real Android activities once for every foreground/background engine.
private object SubtitleActivity : Application.ActivityLifecycleCallbacks {
    private var installed = false
    private val resumed = Collections.newSetFromMap(IdentityHashMap<Activity, Boolean>())
    val foreground: Boolean get() = resumed.isNotEmpty()
    fun install(application: Application) {
        if (installed) return
        installed = true
        application.registerActivityLifecycleCallbacks(this)
    }
    override fun onActivityResumed(activity: Activity) { resumed.add(activity) }
    override fun onActivityPaused(activity: Activity) { resumed.remove(activity) }
    override fun onActivityDestroyed(activity: Activity) { resumed.remove(activity) }
    override fun onActivityCreated(activity: Activity, state: Bundle?) {}
    override fun onActivityStarted(activity: Activity) {}
    override fun onActivityStopped(activity: Activity) {}
    override fun onActivitySaveInstanceState(activity: Activity, state: Bundle) {}
}
