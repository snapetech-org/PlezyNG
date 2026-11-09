// SPDX-License-Identifier: AGPL-3.0-only
#include <jni.h>

#include <codecvt>
#include <locale>

#include "retro_input_files.h"
int RommWorkerMain(int channel);
namespace {
std::string Text(JNIEnv* env, jstring value) {
  if (!value || env->GetStringLength(value) > 4096) throw std::runtime_error("Invalid emulator input name");
  const auto* chars = env->GetStringChars(value, nullptr);
  if (!chars) throw std::runtime_error("Could not read emulator input name");
  std::u16string input(reinterpret_cast<const char16_t*>(chars), env->GetStringLength(value));
  env->ReleaseStringChars(value, chars);
  return std::wstring_convert<std::codecvt_utf8_utf16<char16_t>, char16_t>{}.to_bytes(input);
}
}  // namespace
extern "C" JNIEXPORT void JNICALL Java_com_edde746_plezy_games_RommIsolatedService_runWorker(
    JNIEnv* env, jobject, jint pipe, jstring core, jobjectArray names, jintArray descriptors) {
  // Fail without terminating anything if linked accidentally into the app.
  const auto uid = getuid() % 100000;
  if (uid < 90000 || uid > 99999) return;
  try {
    using namespace plezy::retro;
    if (inputs::configured || !names || !descriptors || pipe < 0)
      throw std::runtime_error("Invalid emulator bootstrap");
    const auto size = env->GetArrayLength(names);
    if (size > 65 || size != env->GetArrayLength(descriptors)) throw std::runtime_error("Invalid emulator input count");
    inputs::core = Text(env, core);
    if (inputs::core != "libgambatte_libretro.so" && inputs::core != "libmgba_libretro.so" &&
        inputs::core != "libfceumm_libretro.so")
      throw std::runtime_error("Unknown bundled emulator");
    std::vector<jint> fds(size);
    env->GetIntArrayRegion(descriptors, 0, size, fds.data());
    if (env->ExceptionCheck()) throw std::runtime_error("Invalid emulator descriptors");
    uint64_t total = 0;
    size_t games = 0;
    for (int n = 0; n < size; ++n) {
      const auto name = static_cast<jstring>(env->GetObjectArrayElement(names, n));
      const auto path = Text(env, name);
      env->DeleteLocalRef(name);
      inputs::Add(path, fds[n]);
      total += inputs::files.at(path).size;
      games += path.rfind("/rom/", 0) == 0;
    }
    if (games > 1 || (size && !games) || total > 384ull * 1024 * 1024)
      throw std::runtime_error("Too many emulator inputs");
    inputs::configured = true;
    RommWorkerMain(pipe);
  } catch (...) {
    std::_Exit(2);
  }
}
