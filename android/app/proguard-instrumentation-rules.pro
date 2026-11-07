# Applied only to the `minified` variant, which exists to run R8 over the app under test.
#
# The instrumentation runner is loaded through the tested app's class loader, and its
# supertypes resolve from the app APK. Shrinking androidx.test there leaves the harness
# with an AndroidJUnitRunner it cannot link, and the run dies with ClassNotFoundException
# before a single test starts — reported as `tests="0"`, which is easy to mistake for a
# passing gate. No shipped build includes this file.
-keep class androidx.test.** { *; }
-dontwarn androidx.test.**

# AndroidJUnitRunner calls this shared dependency from the test APK. Release
# optimization can inline its app callers and remove it from the tested APK,
# while AGP excludes the same dependency from the test APK as already supplied.
-keep class androidx.tracing.** { *; }

# These facade APIs and callback interfaces are called separately by the tests.
# Production optimization can otherwise inline methods or merge interfaces;
# applying the app mapping to the test cannot reconstruct removed descriptors.
# Keep the test entry points, allowing their names to be obfuscated as usual. The
# FFmpeg reflection/JNI keep rules under test remain solely in the production file.
-keep,allowobfuscation class androidx.media3.exoplayer.DefaultRenderersFactory {
    public *;
    protected *;
}
-keep,allowobfuscation interface androidx.media3.exoplayer.video.VideoRendererEventListener { *; }
-keep,allowobfuscation interface androidx.media3.exoplayer.audio.AudioRendererEventListener { *; }
-keep,allowobfuscation interface androidx.media3.exoplayer.text.TextOutput { *; }
-keep,allowobfuscation interface androidx.media3.exoplayer.metadata.MetadataOutput { *; }
-keepclassmembers,allowobfuscation interface androidx.media3.exoplayer.Renderer {
    public java.lang.String getName();
}
-keep,allowobfuscation class com.edde746.plezy.mpv.MpvPlayerCore { public *; }
-keep,allowobfuscation interface com.edde746.plezy.shared.PlayerDelegate { *; }
-keep,allowobfuscation class com.edde746.plezy.shared.PlayerDelegate$DefaultImpls { *; }
