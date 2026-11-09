// SPDX-License-Identifier: AGPL-3.0-only
#include <fcntl.h>

#include "retro_android_process.h"
extern "C" JNIEXPORT jint JNICALL Java_com_edde746_plezy_games_RommProcessBroker_readOnlyInputFlags(JNIEnv*, jclass) {
  return O_RDONLY | O_CLOEXEC | O_NOFOLLOW;
}
extern "C" JNIEXPORT void JNICALL Java_com_edde746_plezy_games_RommProcessBroker_initialize(JNIEnv* env, jclass type) {
  using namespace plezy::retro::android_process;
  if (broker) return;
  if (env->GetJavaVM(&vm) != JNI_OK) return;
  auto worker = env->FindClass("com/edde746/plezy/games/RommProcessBroker$Worker");
  if (!worker) return;
  launch = env->GetStaticMethodID(
      type, "launch",
      "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)Lcom/edde746/plezy/games/RommProcessBroker$Worker;");
  detachFd = env->GetMethodID(worker, "detachFd", "()I");
  closeWorker = env->GetMethodID(worker, "close", "()V");
  isDead = env->GetMethodID(worker, "isDead", "()Z");
  if (env->ExceptionCheck() || !launch || !detachFd || !closeWorker || !isDead) return;
  broker = static_cast<jclass>(env->NewGlobalRef(type));
}
