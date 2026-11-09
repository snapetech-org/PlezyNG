// SPDX-License-Identifier: AGPL-3.0-only
#pragma once
#include <jni.h>

#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>

#include "../../../shared/process/byte_pipe.h"

namespace plezy::retro::android_process {
inline JavaVM* vm = nullptr;
inline jclass broker = nullptr;
inline jmethodID launch = nullptr, detachFd = nullptr, close = nullptr, isDead = nullptr;
class Environment {
  bool attached_ = false;

 public:
  JNIEnv* env = nullptr;
  Environment() {
    if (!vm) throw std::runtime_error("Android emulator broker is unavailable");
    const auto status = vm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6);
    if (status == JNI_EDETACHED) {
      if (vm->AttachCurrentThread(&env, nullptr) != JNI_OK)
        throw std::runtime_error("Could not attach emulator broker");
      attached_ = true;
    } else if (status != JNI_OK)
      throw std::runtime_error("Invalid emulator broker VM");
    if (env->PushLocalFrame(16) < 0) {
      env->ExceptionClear();
      if (attached_) vm->DetachCurrentThread();
      throw std::runtime_error("Could not allocate emulator broker references");
    }
  }
  ~Environment() {
    env->PopLocalFrame(nullptr);
    if (attached_) vm->DetachCurrentThread();
  }
  void Check() {
    if (env->ExceptionCheck()) {
      env->ExceptionClear();
      throw std::runtime_error("Android emulator service failed");
    }
  }
};
class Control {
 public:
  jobject worker = nullptr;
  ~Control() {
    Abort();
    if (worker) try {
        Environment state;
        state.env->DeleteGlobalRef(worker);
      } catch (...) {
      }
  }
  void Abort() noexcept {
    if (worker) try {
        Environment state;
        state.env->CallVoidMethod(worker, close);
        state.Check();
      } catch (...) {
      }
  }
  bool Reaped() noexcept {
    if (!worker) return true;
    try {
      Environment state;
      const auto dead = state.env->CallBooleanMethod(worker, isDead);
      state.Check();
      return dead == JNI_TRUE;
    } catch (...) {
      return false;
    }
  }
};
inline void Retire(const std::shared_ptr<Control>& control) noexcept { control->Abort(); }
inline jstring String(JNIEnv* env, const std::string& value) {
  // JNI NewStringUTF uses modified UTF-8; file names use ordinary UTF-8.
  const auto bytes = env->NewByteArray(static_cast<jsize>(value.size()));
  if (!bytes) return nullptr;
  env->SetByteArrayRegion(bytes, 0, static_cast<jsize>(value.size()), reinterpret_cast<const jbyte*>(value.data()));
  const auto type = env->FindClass("java/lang/String");
  const auto constructor = type ? env->GetMethodID(type, "<init>", "([BLjava/lang/String;)V") : nullptr;
  if (!constructor) return nullptr;
  return static_cast<jstring>(env->NewObject(type, constructor, bytes, env->NewStringUTF("UTF-8")));
}
inline std::unique_ptr<plezy::process::BytePipe> Spawn(
    const std::string& core, const std::string& rom, const std::string& system,
    const std::shared_ptr<Control>& control) {
  Environment state;
  if (!broker || !launch) throw std::runtime_error("Android emulator broker is not initialized");
  auto* env = state.env;
  const auto a = String(env, core), b = String(env, rom), c = String(env, system);
  state.Check();
  if (!a || !b || !c) throw std::runtime_error("Invalid emulator input names");
  const auto object = env->CallStaticObjectMethod(broker, launch, a, b, c);
  state.Check();
  if (!object) throw std::runtime_error("Emulator service is unavailable");
  control->worker = env->NewGlobalRef(object);
  state.Check();
  if (!control->worker) {
    env->CallVoidMethod(object, close);
    state.Check();
    throw std::runtime_error("Could not retain emulator service");
  }
  const auto fd = env->CallIntMethod(object, detachFd);
  state.Check();
  if (fd < 0) throw std::runtime_error("Emulator socket is unavailable");
  return std::make_unique<plezy::process::BytePipe>(fd);
}
}  // namespace plezy::retro::android_process
