package com.edde746.plezy.car

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import com.edde746.plezy.BuildConfig
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodChannel

/** Platform identity and vehicle restrictions must also exist without an Activity. */
class MusicBackgroundPlatformPlugin : FlutterPlugin {
  private var context: Context? = null
  private var device: MethodChannel? = null
  private var restrictions: MethodChannel? = null
  private var monitor: CarRestrictionsMonitor? = null
  private val handler = Handler(Looper.getMainLooper())
  private var generation = 0

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    context = binding.applicationContext
    device = MethodChannel(binding.binaryMessenger, "com.plezy/device")
    restrictions = MethodChannel(binding.binaryMessenger, "com.plezy/car_restrictions")
    activateHeadless()
  }

  fun activateHeadless() {
    val context = context ?: return
    val automotive = context.packageManager.hasSystemFeature(PackageManager.FEATURE_AUTOMOTIVE)
    device?.setMethodCallHandler { call, result ->
      when (call.method) {
        "getTvDetection" -> result.success(
          mapOf(
            "isTv" to false,
            "isAutomotive" to automotive,
            "isAutomotiveMedia" to (automotive && BuildConfig.AUTOMOTIVE_MEDIA),
            "reasons" to emptyList<String>()
          )
        )
        "getDeviceName" -> result.success(Build.MODEL)
        else -> result.notImplemented()
      }
    }
    restrictions?.setMethodCallHandler { call, result ->
      if (call.method == "getState") {
        startMonitor(automotive)
        result.success(state())
      } else {
        result.notImplemented()
      }
    }
    startMonitor(automotive)
  }

  private fun startMonitor(automotive: Boolean) {
    if (!automotive) return
    val context = context ?: return
    val expected = generation
    try {
      val current = monitor ?: CarRestrictionsMonitor(context).also { monitor = it }
      current.start {
        handler.post {
          if (generation == expected) restrictions?.invokeMethod("onChanged", state())
        }
      }
    } catch (_: LinkageError) {
      // Automotive remains identified as Automotive. Dart's unknown-state
      // background policy fails closed if an OEM lacks android.car.
    } catch (_: SecurityException) {
      // Same fail-closed behavior when the OEM denies the car service.
    }
  }

  private fun state(): Map<String, Boolean> = mapOf(
    "supported" to (monitor?.supported == true),
    "pending" to (monitor?.pending == true),
    "requiresDistractionOptimization" to (monitor?.requiresDistractionOptimization != false)
  )

  /** The Activity installs its full device handler and owns vehicle observation. */
  fun suspendForActivity() {
    generation++
    monitor?.release()
    monitor = null
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    suspendForActivity()
    device?.setMethodCallHandler(null)
    restrictions?.setMethodCallHandler(null)
    device = null
    restrictions = null
    context = null
  }
}
