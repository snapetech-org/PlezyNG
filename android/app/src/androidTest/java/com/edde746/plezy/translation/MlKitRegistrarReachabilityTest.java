package com.edde746.plezy.translation;

import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertTrue;

import android.app.Activity;
import android.app.Instrumentation;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.os.Bundle;
import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.platform.app.InstrumentationRegistry;
import java.util.HashSet;
import java.util.Set;
import org.junit.Test;
import org.junit.runner.RunWith;

/** Tests manifest discovery without linking registrars or test-only Kotlin helpers. */
@RunWith(AndroidJUnit4.class)
public class MlKitRegistrarReachabilityTest {
  @Test
  public void minifiedFlutterActivityBootsWithItsPackagedEngine() {
    Instrumentation instrumentation = InstrumentationRegistry.getInstrumentation();
    Context context = instrumentation.getTargetContext();
    Intent launch = context.getPackageManager().getLaunchIntentForPackage(context.getPackageName());
    assertNotNull("The app has no launcher activity", launch);
    launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
    Activity activity = instrumentation.startActivitySync(launch);
    assertNotNull("The minified Flutter activity did not start", activity);
    instrumentation.waitForIdleSync();
    instrumentation.runOnMainSync(activity::finish);
  }

  @Test
  public void manifestRegistrarsRemainConstructibleAfterShrinking() throws Exception {
    Context context = InstrumentationRegistry.getInstrumentation().getTargetContext();
    ComponentName service = new ComponentName(
        context, "com.google.mlkit.common.internal.MlKitComponentDiscoveryService");
    Bundle metadata = context.getPackageManager()
        .getServiceInfo(service, PackageManager.GET_META_DATA).metaData;
    assertNotNull("ML Kit discovery metadata is absent from the merged manifest", metadata);
    String prefix = "com.google.firebase.components:";
    Set<String> registrars = new HashSet<>();
    for (String key : metadata.keySet()) {
      if (key.startsWith(prefix)) registrars.add(key.substring(prefix.length()));
    }
    assertTrue("Translation registrar is absent from the merged manifest", registrars.contains(
        "com.google.mlkit.nl.translate.NaturalLanguageTranslateRegistrar"));
    for (String name : registrars) {
      Object instance = Class.forName(name, true, context.getClassLoader())
          .getDeclaredConstructor().newInstance();
      assertNotNull("Manifest registrar could not be constructed: " + name, instance);
    }
  }
}
