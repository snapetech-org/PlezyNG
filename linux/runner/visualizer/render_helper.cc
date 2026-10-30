// SPDX-License-Identifier: AGPL-3.0-only
#include "../../../shared/visualization/render_helper.h"
#include <epoxy/egl.h>
#include <epoxy/gl.h>
#include <gdk-pixbuf/gdk-pixbuf.h>
#include <cstring>

using namespace plezy::visualization;
namespace {
struct ProjectMApi {
  void* library = nullptr;
  std::string error;
  void* (*create)() = nullptr;
  void (*destroy)(void*) = nullptr;
  void (*version)(int*, int*, int*) = nullptr;
  void (*load)(void*, const char*, bool) = nullptr;
  void (*resize)(void*, size_t, size_t) = nullptr;
  void (*paths)(void*, const char**, size_t) = nullptr;
  void (*lock)(void*, bool) = nullptr;
  void (*failed)(void*, void (*)(const char*, const char*, void*), void*) = nullptr;
  void (*pcm)(void*, const float*, unsigned int, int) = nullptr;
  unsigned int (*max_samples)() = nullptr;
  int (*render)(void*, unsigned int) = nullptr;
  void (*pause)(void*, bool) = nullptr;
  void (*soft_cut)(void*, double) = nullptr;
  void (*fps)(void*, int32_t) = nullptr;

  ProjectMApi() {
    library = dlopen("libprojectM-4.so.4", RTLD_NOW | RTLD_LOCAL);
    if (!library) {
      error = "The native projectM renderer is not installed in this build.";
      return;
    }
#define LOAD(field, symbol)                                                    \
  field = reinterpret_cast<decltype(field)>(dlsym(library, symbol));           \
  if (!field) {                                                                \
    error = "The projectM dependency lacks the pinned Plezy framebuffer API."; \
    return;                                                                    \
  }
    LOAD(create, "projectm_create")
    LOAD(destroy, "projectm_destroy")
    LOAD(version, "projectm_get_version_components")
    LOAD(load, "projectm_load_preset_file")
    LOAD(resize, "projectm_set_window_size")
    LOAD(paths, "projectm_set_texture_search_paths")
    LOAD(lock, "projectm_set_preset_locked")
    LOAD(failed, "projectm_set_preset_switch_failed_event_callback")
    LOAD(pcm, "projectm_pcm_add_float")
    LOAD(max_samples, "projectm_pcm_get_max_samples")
    LOAD(render, "projectm_plezy_render_frame_fbo")
    LOAD(pause, "projectm_plezy_set_paused")
    LOAD(soft_cut, "projectm_set_soft_cut_duration")
    LOAD(fps, "projectm_set_fps")
#undef LOAD
    int major = 0, minor = 0, patch = 0;
    version(&major, &minor, &patch);
    if (major != 4 || minor != 1 || patch != 8) error = "This build requires the pinned projectM 4.1.8 dependency.";
  }
  ~ProjectMApi() {
    if (library) dlclose(library);
  }
};
ProjectMApi& Api() {
  static auto* api = new ProjectMApi(); // Quarantined driver calls retain this mapping.
  return *api;
}

// An independent surfaceless Mesa EGL display avoids sharing or altering
// Flutter's context and the Wayland video plane's context/display lifecycle.
struct OffscreenContext {
  EGLDisplay display = EGL_NO_DISPLAY;
  EGLSurface surface = EGL_NO_SURFACE;
  EGLContext context = EGL_NO_CONTEXT;
  GLuint framebuffer = 0, texture = 0;
  int width = 0, height = 0;
  void Initialize() {
    using GetDisplay = EGLDisplay (*)(EGLenum, void*, const EGLint*);
    auto get_display = reinterpret_cast<GetDisplay>(eglGetProcAddress("eglGetPlatformDisplayEXT"));
    if (!get_display) throw std::runtime_error("Surfaceless EGL is unavailable on this driver.");
    display = get_display(0x31DD /* EGL_PLATFORM_SURFACELESS_MESA */, EGL_DEFAULT_DISPLAY, nullptr);
    if (display == EGL_NO_DISPLAY || !eglInitialize(display, nullptr, nullptr))
      throw std::runtime_error("Could not initialize the offscreen visualization display.");
    if (!eglBindAPI(EGL_OPENGL_ES_API)) throw std::runtime_error("OpenGL ES is unavailable.");
    EGLint attributes[] = {
        EGL_SURFACE_TYPE,
        EGL_PBUFFER_BIT,
        EGL_RENDERABLE_TYPE,
        0x0040,
        EGL_RED_SIZE,
        8,
        EGL_GREEN_SIZE,
        8,
        EGL_BLUE_SIZE,
        8,
        EGL_ALPHA_SIZE,
        8,
        EGL_NONE};
    EGLConfig config{};
    EGLint count = 0;
    if (!eglChooseConfig(display, attributes, &config, 1, &count) || count != 1)
      throw std::runtime_error("No GLES 3 configuration for visualization.");
    EGLint pbuffer[] = {EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE};
    surface = eglCreatePbufferSurface(display, config, pbuffer);
    EGLint context_attributes[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
    context = eglCreateContext(display, config, EGL_NO_CONTEXT, context_attributes);
    if (surface == EGL_NO_SURFACE || context == EGL_NO_CONTEXT || !eglMakeCurrent(display, surface, surface, context))
      throw std::runtime_error("Could not create a visualization GLES context.");
  }
  void Resize(int w, int h) {
    if (w == width && h == height) return;
    if (framebuffer) glDeleteFramebuffers(1, &framebuffer);
    if (texture) glDeleteTextures(1, &texture);
    framebuffer = texture = 0;
    glGenTextures(1, &texture);
    glBindTexture(GL_TEXTURE_2D, texture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
    glGenFramebuffers(1, &framebuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, texture, 0);
    if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE)
      throw std::runtime_error("Visualization framebuffer is incomplete.");
    width = w;
    height = h;
  }
  ~OffscreenContext() {
    if (context != EGL_NO_CONTEXT && display != EGL_NO_DISPLAY) {
      eglMakeCurrent(display, surface, surface, context);
      if (framebuffer) glDeleteFramebuffers(1, &framebuffer);
      if (texture) glDeleteTextures(1, &texture);
      eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
      eglDestroyContext(display, context);
    }
    if (surface != EGL_NO_SURFACE) eglDestroySurface(display, surface);
    if (display != EGL_NO_DISPLAY) eglTerminate(display);
  }
};
plezy::visualization::MilkRustImage DecodeImage(const std::filesystem::path& path) {
  const auto length = std::filesystem::file_size(path);
  if (length == 0 || length > 16 * 1024 * 1024) throw std::runtime_error("Texture file exceeds its byte limit.");
  std::ifstream input(path, std::ios::binary);
  std::vector<uint8_t> bytes(static_cast<size_t>(length));
  if (!input.read(reinterpret_cast<char*>(bytes.data()), static_cast<std::streamsize>(bytes.size())) ||
      input.peek() != EOF)
    throw std::runtime_error("Texture changed while reading.");
  g_autoptr(GdkPixbufLoader) loader = gdk_pixbuf_loader_new();
  struct Size {
    bool seen = false, rejected = false;
  } size;
  g_signal_connect(
      loader, "size-prepared", G_CALLBACK(+[](GdkPixbufLoader* loader, int width, int height, gpointer data) {
        auto* size = static_cast<Size*>(data);
        size->seen = true;
        size->rejected = width <= 0 || height <= 0 || width > 4096 || height > 4096 ||
                         static_cast<uint64_t>(width) * height > 8 * 1024 * 1024;
        if (size->rejected) gdk_pixbuf_loader_set_size(loader, 1, 1);
      }),
      &size);
  g_autoptr(GError) error = nullptr;
  for (size_t offset = 0; offset < bytes.size();) {
    const auto chunk = std::min<size_t>(4096, bytes.size() - offset);
    if (!gdk_pixbuf_loader_write(loader, bytes.data() + offset, chunk, &error) || size.rejected)
      throw std::runtime_error("Texture decode failed or image dimensions exceed the limit.");
    offset += chunk;
  }
  if (!gdk_pixbuf_loader_close(loader, &error) || !size.seen || size.rejected)
    throw std::runtime_error("Texture decoder did not produce a bounded image.");
  auto* image = gdk_pixbuf_loader_get_pixbuf(loader);
  if (!image || gdk_pixbuf_get_bits_per_sample(image) != 8) throw std::runtime_error("Unsupported image pixel format.");
  plezy::visualization::MilkRustImage result;
  result.width = gdk_pixbuf_get_width(image);
  result.height = gdk_pixbuf_get_height(image);
  const int channels = gdk_pixbuf_get_n_channels(image), stride = gdk_pixbuf_get_rowstride(image);
  if (channels != 3 && channels != 4) throw std::runtime_error("Unsupported image channel count.");
  result.rgba.resize(static_cast<size_t>(result.width) * result.height * 4);
  const auto* pixels = gdk_pixbuf_read_pixels(image);
  for (uint32_t y = 0; y < result.height; ++y)
    for (uint32_t x = 0; x < result.width; ++x) {
      const auto* src = pixels + y * stride + x * channels;
      auto* dst = result.rgba.data() + (static_cast<size_t>(y) * result.width + x) * 4;
      std::copy(src, src + 3, dst);
      dst[3] = channels == 4 ? src[3] : 255;
    }
  return result;
}

class Context final : public NativeContext {
  OffscreenContext context_;
 public:
  Context() { context_.Initialize(); }
  milkrust_gl_loader Loader() const override {
    return +[](const char* name) -> const void* { return reinterpret_cast<const void*>(eglGetProcAddress(name)); };
  }
  bool IsGles() const override { return true; }
};

class ProjectMBackend final : public RenderBackend {
  OffscreenContext graphics_;
  std::string error_;
  void* instance_ = nullptr;
  bool loaded_ = false;
 public:
  ProjectMBackend() {
    if (!Api().error.empty()) throw std::runtime_error(Api().error);
    graphics_.Initialize();
  }
  ~ProjectMBackend() override { if (instance_) Api().destroy(instance_); }
  void Reset() override {
    if (instance_) { Api().destroy(instance_); instance_ = nullptr; }
    loaded_ = false; error_.clear();
    graphics_.Resize(768, 432);
    instance_ = Api().create();
    if (!instance_) throw std::runtime_error("projectM could not initialize.");
    Api().failed(instance_, [](const char*, const char* message, void* target) {
      *static_cast<std::string*>(target) = message ? message : "Preset loading failed.";
    }, &error_);
    Api().lock(instance_, true); Api().fps(instance_, 30);
  }
  void Load(const std::string& path, const std::string& root, double transition = 0) override {
    if (!instance_) throw std::runtime_error("projectM has not been reset.");
    const auto base = std::filesystem::canonical(std::filesystem::u8path(root));
    const auto preset = std::filesystem::canonical(std::filesystem::u8path(path));
    const auto relative = preset.lexically_relative(base);
    auto extension = preset.extension().u8string();
    for (auto& value : extension) if (value >= 'A' && value <= 'Z') value += 'a' - 'A';
    if (relative.empty() || *relative.begin() == ".." || extension != ".milk" ||
        !std::filesystem::is_regular_file(preset) || std::filesystem::file_size(preset) > 2 * 1024 * 1024)
      throw std::runtime_error("projectM requires a bounded .milk preset inside its pack.");
    const auto root_path = base.string(), textures = (base / "textures").string();
    const char* roots[] = {root_path.c_str(), textures.c_str()};
    Api().paths(instance_, roots, 2); Api().soft_cut(instance_, std::max(0.01, transition));
    error_.clear(); Api().load(instance_, preset.c_str(), loaded_ && transition > 0);
    if (!error_.empty()) throw std::runtime_error(error_);
    loaded_ = true;
  }
  void Pcm(const float* samples, size_t frames, uint32_t) override {
    if (!instance_) throw std::runtime_error("projectM has not been reset.");
    const auto maximum = Api().max_samples();
    if (!maximum) throw std::runtime_error("Invalid projectM PCM capacity.");
    for (size_t offset = 0; offset < frames;) {
      const auto count = static_cast<unsigned int>(std::min<size_t>(maximum, frames - offset));
      Api().pcm(instance_, samples + offset * 2, count, 2); offset += count;
    }
  }
  void Pause(bool paused) override { if (instance_) Api().pause(instance_, paused); }
  void Capture(uint32_t width, uint32_t height, double, std::vector<uint8_t>& rgba) override {
    if (!instance_ || !loaded_) throw std::runtime_error("projectM has no loaded preset.");
    const auto bytes = render_protocol::FrameBytes(width, height);
    graphics_.Resize(static_cast<int>(width), static_cast<int>(height));
    Api().resize(instance_, width, height);
    if (Api().render(instance_, graphics_.framebuffer) != 0) throw std::runtime_error("projectM failed to render.");
    rgba.resize(bytes);
    glBindFramebuffer(GL_FRAMEBUFFER, graphics_.framebuffer);
    glPixelStorei(GL_PACK_ALIGNMENT, 1);
    glReadPixels(0, 0, width, height, GL_RGBA, GL_UNSIGNED_BYTE, rgba.data());
    if (glGetError() != GL_NO_ERROR) throw std::runtime_error("Visualization frame readback failed.");
    const size_t stride = size_t(width) * 4;
    for (uint32_t y = 0; y < height / 2; ++y)
      std::swap_ranges(rgba.begin() + y * stride, rgba.begin() + (y + 1) * stride,
          rgba.begin() + (height - y - 1) * stride);
  }
};
}
int main(int argc, char** argv) {
  if (argc != 3 || std::strcmp(argv[1], "--plezy-render-pipe") || std::strcmp(argv[2], "3")) return 64;
  RunRenderHelper(3, [](render_protocol::Backend kind) -> std::unique_ptr<RenderBackend> {
    if (kind == render_protocol::Backend::ProjectM) return std::make_unique<ProjectMBackend>();
    return std::make_unique<LocalRenderBackend>(std::make_unique<Context>(), DecodeImage);
  });
}
