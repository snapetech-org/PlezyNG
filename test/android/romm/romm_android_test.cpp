// SPDX-License-Identifier: AGPL-3.0-only
#include <jni.h>

#include <chrono>
#include <cstdlib>
#include <stdexcept>
#include <string>
#include <thread>

#include "../../../native/games/romm/retro_api.h"
namespace {
using Clock = std::chrono::steady_clock;
void Check(bool value, const char* error) {
  if (!value) throw std::runtime_error(error);
}
void Reap() {
  const auto deadline = Clock::now() + std::chrono::seconds(5);
  while (!plezy_retro_shutdown_complete() && Clock::now() < deadline)
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
  Check(plezy_retro_shutdown_complete() == 1, "Android did not confirm worker death");
}
}  // namespace
extern "C" JNIEXPORT void JNICALL
Java_org_pleazyng_romm_test_ContainmentTest_exercise(JNIEnv* env, jobject, jstring root, jint mode) {
  const auto* text = env->GetStringUTFChars(root, nullptr);
  if (!text) return;
  const std::string directory(text);
  env->ReleaseStringUTFChars(root, text);
  try {
    setenv("PLEZY_TEST_SECRET", "DUMMY_ENVIRONMENT_CREDENTIAL", 1);
    Check(plezy_retro_isolation_version() == 1, "Android loaded an in-process host");
    Check(plezy_retro_has_core("libgambatte_libretro.so") == 1, "Isolated Android probe failed");
    Reap();
    Check(
        plezy_retro_open(
            "libgambatte_libretro.so", (directory + "/game.bin").c_str(), (directory + "/system").c_str(),
            (directory + "/saves").c_str()) == 1,
        "Isolated Android open failed");
    const auto start = Clock::now();
    if (mode == 'D')
      plezy_retro_close();
    else if (mode == 'M') {
      Check(plezy_retro_capture(1) == 0, "Oversized Android state accepted");
    } else {
      plezy_retro_run();
      if (mode == 'P') {
        Check(
            plezy_retro_healthy() && plezy_retro_width() == 2 && plezy_retro_frame()[0] == 255,
            "Android frame changed");
        const uint8_t state[]{7, 8, 9};
        Check(
            plezy_retro_restore(state, 3, 1) == 1 && plezy_retro_capture(1) == 3 && plezy_retro_snapshot()[0] == 7,
            "Android save round trip failed");
      } else
        Check(!plezy_retro_healthy(), "Faulty Android worker remained healthy");
    }
    plezy_retro_close();
    Reap();
    Check(Clock::now() - start < std::chrono::seconds(8), "Android failure exceeded its deadline");
  } catch (const std::exception& error) {
    plezy_retro_close();
    env->ThrowNew(env->FindClass("java/lang/AssertionError"), error.what());
  }
}
