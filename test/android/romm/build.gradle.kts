plugins {
  id("com.android.application") version "9.3.1"
  id("org.jetbrains.kotlin.android") version "2.4.10"
}
android {
  namespace = "org.pleazyng.romm.test"
  compileSdk = 37
  buildToolsVersion = "36.1.0"
  ndkVersion = "29.0.14206865"
  defaultConfig {
    applicationId = "org.pleazyng.romm.test"
    minSdk = 25
    targetSdk = 35
    testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    ndk { abiFilters += listOf("arm64-v8a", "armeabi-v7a", "x86", "x86_64") }
    externalNativeBuild { cmake { arguments += "-DCMAKE_BUILD_TYPE=Debug" } }
  }
  compileOptions {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
  }
  sourceSets.getByName("main").java.srcDir("../../../android/app/src/main/kotlin/com/edde746/plezy/games")
  externalNativeBuild { cmake { path = file("CMakeLists.txt"); version = "3.22.1" } }
}
kotlin { compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) } }
dependencies {
  androidTestImplementation("androidx.test:runner:1.7.0")
  androidTestImplementation("androidx.test.ext:junit:1.3.0")
}
