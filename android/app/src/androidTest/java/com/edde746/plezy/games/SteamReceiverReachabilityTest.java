package com.edde746.plezy.games;

import static org.junit.Assert.assertTrue;

import android.content.Context;
import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.platform.app.InstrumentationRegistry;
import java.lang.reflect.Method;
import java.util.Map;
import org.junit.Test;
import org.junit.runner.RunWith;

/** Runs against the minified app. String-only reflection must not add R8 roots. */
@RunWith(AndroidJUnit4.class)
public final class SteamReceiverReachabilityTest {
  private Class<?> target(String name) throws Exception {
    return Class.forName(
        "org.snapetech.plezyng.games.steam." + name, true,
        InstrumentationRegistry.getInstrumentation().getTargetContext().getClassLoader());
  }

  @Test
  public void packagedNativeReceiverCreatesAndRetiresWithoutNetwork() throws Exception {
    Class<?> nativeClass = target("NativeSteam"); // Loads the actual packaged .so.
    Method create = nativeClass.getDeclaredMethod("create");
    Method cancel = nativeClass.getDeclaredMethod("cancel", long.class);
    Method destroy = nativeClass.getDeclaredMethod("destroy", long.class);
    create.setAccessible(true);
    cancel.setAccessible(true);
    destroy.setAccessible(true);
    long handle = (Long) create.invoke(null);
    assertTrue("Native receiver allocation failed", handle != 0);
    try {
      cancel.invoke(null, handle);
    } finally {
      destroy.invoke(null, handle);
    }
  }

  @Test
  public void flutterReflectionAndNativeCallbacksSurviveShrinking() throws Exception {
    target("EmbeddedSteam").getMethod("execute", Context.class, String.class, Map.class);
    Class<?> view = target("SteamStreamView");
    view.getConstructor(Context.class, Map.class);
    view.getMethod("setMicrophoneEnabled", boolean.class);
    view.getMethod("setControllerMotion", int.class, double[].class);
    view.getMethod("setControllerMapping", int.class, java.util.List.class);
    view.getMethod("inputText", byte[].class);
    view.getMethod("setInputEnabled", boolean.class);
    view.getMethod("setAudioEnabled", boolean.class);
    for (String name : new String[] {
             "readControllerFeedback", "getMicrophoneState", "getSessionState", "getStreamMetrics", "resetInput",
             "close", "awaitTermination"}) {
      view.getMethod(name);
    }
    Class<?> decoder = target("SteamDecoder");
    // These descriptors are resolved by native code, not ordinary Java calls.
    decoder.getMethod("onVideo", int.class, int.class, int.class, byte[].class);
    decoder.getMethod("onFrame", byte[].class, int.class, boolean.class);
    decoder.getMethod("onAudio", int.class, int.class);
    decoder.getMethod("onAudioUnavailable");
    decoder.getMethod("onSamples", short[].class);
  }
}
