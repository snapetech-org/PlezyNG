package com.edde746.plezy.mpv

import android.content.Context
import android.media.AudioDeviceInfo
import android.media.AudioManager
import com.google.common.collect.ImmutableList
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.shadows.AudioDeviceInfoBuilder
import org.robolectric.util.ReflectionHelpers

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33])
class MusicAudioRouteBridgeTest {
  private lateinit var audio: AudioManager

  @Before
  fun setup() {
    audio = RuntimeEnvironment.getApplication().getSystemService(Context.AUDIO_SERVICE) as AudioManager
  }

  private fun device(address: String, type: Int = AudioDeviceInfo.TYPE_BLUETOOTH_A2DP): AudioDeviceInfo {
    val value = AudioDeviceInfoBuilder.newBuilder().setType(type).build()
    val port = ReflectionHelpers.getField<Any>(value, "mPort")
    ReflectionHelpers.setField(port, "mAddress", address)
    ReflectionHelpers.setField(port, "mName", "Selected output")
    ReflectionHelpers.setField(port, "mRole", 2) // AudioPort.ROLE_SINK in the SDK's hidden port model.
    return value
  }

  private fun route(vararg selected: AudioDeviceInfo) {
    shadowOf(audio).setAudioDevicesForAttributes(MusicAudioRouteSnapshot.attributes, ImmutableList.copyOf(selected))
  }

  @Suppress("UNCHECKED_CAST")
  private fun outputs(): List<Map<String, Any>> = MusicAudioRouteSnapshot.read(audio)!!["outputs"] as List<Map<String, Any>>

  @Test
  fun availableBluetoothAndCommunicationDevicesCannotSubstituteForMediaSelection() {
    val car = device("car")
    shadowOf(audio).setOutputDevices(listOf(car))
    shadowOf(audio).setAvailableCommunicationDevices(listOf(car))
    route(device("", AudioDeviceInfo.TYPE_BUILTIN_SPEAKER))
    assertTrue(outputs().isEmpty())
    assertNull(audio.communicationDevice)
  }

  @Test
  fun selectedMusicRoutesKeepStableAddressesAndReportUnknownFormats() {
    route(device("car"))
    val rows = outputs()
    assertEquals("8:car", rows.single()["id"])
    assertEquals(true, rows.single()["bluetooth"])
    assertEquals(0, rows.single()["channels"])
    assertEquals(0.0, MusicAudioRouteSnapshot.read(audio)!!["sampleRate"])
    assertEquals(0, MusicAudioRouteSnapshot.read(audio)!!["outputChannels"])
    route(device("different-car"))
    assertFalse(outputs().single()["id"] == rows.single()["id"])
  }

  @Test
  fun maskedOrInvalidAddressesCannotBecomeRememberedIdentities() {
    route(device(""), device("bad\u0000address"), device("x".repeat(481)), device("02:00:00:00:00:00"), device("00:00:00:00:00:00"))
    assertTrue(outputs().isEmpty())
  }

  @Test
  fun unknownRoutingDoesNotFallBackToAvailableOutputs() {
    shadowOf(audio).setOutputDevices(listOf(device("available-car")))
    assertNull(MusicAudioRouteSnapshot.read(audio))
  }

  @Test
  @Config(sdk = [32])
  fun oldAndroidDoesNotGuessMusicRoutesFromConnectedDevices() {
    shadowOf(audio).setOutputDevices(listOf(device("connected-car")))
    assertNull(MusicAudioRouteSnapshot.read(audio))
  }

  @Test
  fun duplicateAndExcessiveSelectedPathsRemainBounded() {
    val car = device("car")
    route(car, car)
    assertEquals(1, outputs().size)
    route(*Array(20) { device("route-$it") })
    assertEquals(16, outputs().size)
  }
}
