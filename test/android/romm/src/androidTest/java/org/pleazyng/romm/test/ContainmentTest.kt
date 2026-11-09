package org.pleazyng.romm.test

import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.edde746.plezy.games.RommProcessBroker
import java.io.File
import java.net.ServerSocket
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ContainmentTest {
  private external fun exercise(root: String, mode: Int)

  @Test fun isolatedUidFilesNetworkFaultsAndRestart() {
    val app = InstrumentationRegistry.getInstrumentation().targetContext
    RommProcessBroker.attach(app)
    System.loadLibrary("romm_android_test")
    val root = File(app.filesDir, "containment").apply { mkdirs() }
    File(root, "system").mkdirs()
    File(root, "saves").mkdirs()
    val secret = File(app.filesDir, "credential-fixture").apply { writeText("DUMMY-CREDENTIAL") }
    File(root, "system/bios.bin").writeText("DUMMY-FIRMWARE")
    ServerSocket(0).use { server ->
      for (mode in listOf('P', 'C', 'P', 'H', 'P', 'M', 'P', 'D', 'P', 'S', 'P')) {
        File(root, "game.bin").writeText("$mode\n${secret.path}\n${server.localPort}\n")
        exercise(root.path, mode.code)
        assertEquals("DUMMY-CREDENTIAL", secret.readText())
      }
    }
    assertThrows(IllegalArgumentException::class.java) {
      RommProcessBroker.launch(secret.path, "", "")
    }
  }
}
