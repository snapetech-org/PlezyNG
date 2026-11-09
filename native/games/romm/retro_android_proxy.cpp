// SPDX-License-Identifier: AGPL-3.0-only
#include "retro_android_process.h"
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
  close = env->GetMethodID(worker, "close", "()V");
  isDead = env->GetMethodID(worker, "isDead", "()Z");
  if (env->ExceptionCheck() || !launch || !detachFd || !close || !isDead) return;
  broker = static_cast<jclass>(env->NewGlobalRef(type));
}
