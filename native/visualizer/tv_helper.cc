// SPDX-License-Identifier: AGPL-3.0-only
#include "../../shared/visualization/render_helper.h"
#include "../../shared/visualization/bounded_stb_decoder.h"
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <dlfcn.h>
#include <string>
using namespace plezy::visualization;
namespace {
struct EglApi {
  // Firmware library names differ. Resolve EGL/GLES inside this process only.
  void* library = dlopen("libEGL.so.1", RTLD_NOW | RTLD_LOCAL);
  void* gles = dlopen("libGLESv2.so.2", RTLD_NOW | RTLD_LOCAL);
  void* Symbol(const char* name) {
    if (!library) library = dlopen("libEGL.so", RTLD_NOW | RTLD_LOCAL);
    return library ? dlsym(library, name) : nullptr;
  }
#define EGL_API(name) decltype(&::name) name = reinterpret_cast<decltype(&::name)>(Symbol(#name));
  EGL_API(eglGetDisplay) EGL_API(eglInitialize) EGL_API(eglBindAPI)
  EGL_API(eglChooseConfig) EGL_API(eglCreatePbufferSurface) EGL_API(eglCreateContext)
  EGL_API(eglMakeCurrent) EGL_API(eglDestroyContext) EGL_API(eglDestroySurface)
  EGL_API(eglReleaseThread) EGL_API(eglGetProcAddress)
#undef EGL_API
  bool Available() const {
    return eglGetDisplay && eglInitialize && eglBindAPI && eglChooseConfig && eglCreatePbufferSurface &&
        eglCreateContext && eglMakeCurrent && eglDestroyContext && eglDestroySurface && eglReleaseThread && eglGetProcAddress;
  }
  EglApi() { if (!gles) gles = dlopen("libGLESv2.so", RTLD_NOW | RTLD_LOCAL); }
  static EglApi& Get() { static EglApi api; return api; }
};

class EglContext final : public NativeContext {
 public:
  EglContext() {
    try {
      if (!api_.Available()) throw std::runtime_error("The TV EGL library is unavailable.");
      display_ = api_.eglGetDisplay(EGL_DEFAULT_DISPLAY);
      EGLint major = 0, minor = 0;
      if (display_ == EGL_NO_DISPLAY || !api_.eglInitialize(display_, &major, &minor) || !api_.eglBindAPI(EGL_OPENGL_ES_API))
        throw std::runtime_error("TV EGL initialization failed.");
      const EGLint attributes[] = {EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT_KHR,
          EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8, EGL_NONE};
      EGLConfig config{}; EGLint count = 0;
      if (!api_.eglChooseConfig(display_, attributes, &config, 1, &count) || !count)
        throw std::runtime_error("The TV does not expose a GLES 3 pbuffer configuration.");
      const EGLint surface_attributes[] = {EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE};
      surface_ = api_.eglCreatePbufferSurface(display_, config, surface_attributes);
      const EGLint context_attributes[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
      context_ = api_.eglCreateContext(display_, config, EGL_NO_CONTEXT, context_attributes);
      if (surface_ == EGL_NO_SURFACE || context_ == EGL_NO_CONTEXT ||
          !api_.eglMakeCurrent(display_, surface_, surface_, context_))
        throw std::runtime_error("Could not create the TV visualization context.");
    } catch (...) { Release(); throw; }
  }
  ~EglContext() override { Release(); }
  milkrust_gl_loader Loader() const override { return Proc; }
  bool IsGles() const override { return true; }
 private:
  EglApi& api_ = EglApi::Get();
  EGLDisplay display_ = EGL_NO_DISPLAY;
  EGLContext context_ = EGL_NO_CONTEXT;
  EGLSurface surface_ = EGL_NO_SURFACE;
  static const void* Proc(const char* name) {
    auto& api = EglApi::Get();
    auto address = api.eglGetProcAddress(name);
    if (address) return reinterpret_cast<const void*>(address);
    auto* symbol = dlsym(RTLD_DEFAULT, name);
    return symbol ? symbol : api.gles ? dlsym(api.gles, name) : nullptr;
  }
  void Release() {
    if (display_ == EGL_NO_DISPLAY) return;
    api_.eglMakeCurrent(display_, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    if (context_ != EGL_NO_CONTEXT) api_.eglDestroyContext(display_, context_);
    if (surface_ != EGL_NO_SURFACE) api_.eglDestroySurface(display_, surface_);
    // Flutter may own the same EGLDisplay. Never terminate that shared display.
    context_ = EGL_NO_CONTEXT; surface_ = EGL_NO_SURFACE; display_ = EGL_NO_DISPLAY;
    api_.eglReleaseThread();
  }
};

}  // namespace
int main(int argc, char** argv) {
  if (argc != 3 || std::string(argv[1]) != "--plezy-render-pipe" || std::string(argv[2]) != "3") return 64;
  RunRenderHelper(3, [](render_protocol::Backend kind) -> std::unique_ptr<RenderBackend> {
    if (kind != render_protocol::Backend::MilkRust) throw std::runtime_error("TV helpers support MilkRust rendering.");
    return std::make_unique<LocalRenderBackend>(std::make_unique<EglContext>(), DecodeBoundedImage);
  });
}
