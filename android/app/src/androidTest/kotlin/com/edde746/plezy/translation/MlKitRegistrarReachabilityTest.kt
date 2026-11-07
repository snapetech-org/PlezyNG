package com.edde746.plezy.translation

import android.content.ComponentName
import android.content.pm.PackageManager
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/** Tests the manifest discovery contract without linking registrar classes from the harness. */
@RunWith(AndroidJUnit4::class)
class MlKitRegistrarReachabilityTest {
  @Test
  fun manifestRegistrarsRemainConstructibleAfterShrinking() {
    val context = InstrumentationRegistry.getInstrumentation().targetContext
    val service = ComponentName(context, "com.google.mlkit.common.internal.MlKitComponentDiscoveryService")
    val metadata = requireNotNull(context.packageManager.getServiceInfo(service, PackageManager.GET_META_DATA).metaData) {
      "ML Kit discovery metadata is absent from the merged manifest"
    }
    val prefix = "com.google.firebase.components:"
    val registrars = metadata.keySet().filter { it.startsWith(prefix) }.map { it.removePrefix(prefix) }
    assertTrue(
      "Translation registrar is absent from the merged manifest",
      registrars.contains(
        "com.google.mlkit.nl.translate.NaturalLanguageTranslateRegistrar"
      )
    )
    for (name in registrars) {
      val instance = Class.forName(name, true, context.classLoader).getDeclaredConstructor().newInstance()
      assertNotNull("Manifest registrar could not be constructed: $name", instance)
    }
  }
}
