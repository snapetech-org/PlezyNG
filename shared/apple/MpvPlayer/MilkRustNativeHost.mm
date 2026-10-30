// SPDX-License-Identifier: AGPL-3.0-only
#import "MilkRustNativeHost.h"
#import <TargetConditionals.h>
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>
#if TARGET_OS_OSX
#import <OpenGL/OpenGL.h>
#else
#import <OpenGLES/EAGL.h>
#endif
#include "../../visualization/native_worker.h"
#if TARGET_OS_OSX
#include "../../visualization/render_process.h"
#endif
#include <dlfcn.h>
#include <cstring>

using namespace plezy::visualization;
struct mpv_handle;
namespace {
struct TapApi {
  int (*version)() = reinterpret_cast<int(*)()>(dlsym(RTLD_DEFAULT, "mpv_plezy_audio_tap_version"));
  int (*enable)(mpv_handle*, int) = reinterpret_cast<int(*)(mpv_handle*, int)>(dlsym(RTLD_DEFAULT, "mpv_plezy_audio_tap_enable"));
  int (*read)(mpv_handle*, double, mpv_plezy_audio_block*, size_t) = reinterpret_cast<int(*)(mpv_handle*, double, mpv_plezy_audio_block*, size_t)>(dlsym(RTLD_DEFAULT, "mpv_plezy_audio_tap_read"));
  int (*read_next)(mpv_handle*, mpv_plezy_audio_block*, size_t) = reinterpret_cast<int(*)(mpv_handle*, mpv_plezy_audio_block*, size_t)>(dlsym(RTLD_DEFAULT, "mpv_plezy_audio_tap_read_next"));
  bool available() const { return version && enable && read && version() == MPV_PLEZY_AUDIO_TAP_ABI; }
  bool subtitle_available() const { return version && enable && read_next && version() == MPV_PLEZY_AUDIO_TAP_ABI; }
};
TapApi& Tap() { static TapApi api; return api; }
class AppleContext final : public NativeContext {
 public:
  AppleContext() {
#if TARGET_OS_OSX
    CGLPixelFormatAttribute attrs[] = {kCGLPFAOpenGLProfile,
        static_cast<CGLPixelFormatAttribute>(kCGLOGLPVersion_4_1_Core), kCGLPFAAccelerated,
        static_cast<CGLPixelFormatAttribute>(0)};
    CGLPixelFormatObj format = nullptr; GLint count = 0;
    auto result = CGLChoosePixelFormat(attrs, &format, &count);
    if (result != kCGLNoError || !format) throw std::runtime_error("No macOS OpenGL 4.1 core configuration.");
    result = CGLCreateContext(format, nullptr, &context_); CGLDestroyPixelFormat(format);
    if (result != kCGLNoError || !context_) throw std::runtime_error("Could not create the macOS visualization context.");
    if (CGLSetCurrentContext(context_) != kCGLNoError) {
      CGLDestroyContext(context_); context_ = nullptr;
      throw std::runtime_error("Could not activate the macOS visualization context.");
    }
#else
    context_ = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES3];
    if (!context_ || ![EAGLContext setCurrentContext:context_])
      throw std::runtime_error("Could not create an OpenGL ES 3 visualization context.");
#endif
  }
  ~AppleContext() override {
#if TARGET_OS_OSX
    CGLSetCurrentContext(nullptr); if (context_) CGLDestroyContext(context_);
#else
    [EAGLContext setCurrentContext:nil]; context_ = nil;
#endif
  }
  milkrust_gl_loader Loader() const override {
    return +[](const char* name) -> const void* { return dlsym(RTLD_DEFAULT, name); };
  }
  bool IsGles() const override {
#if TARGET_OS_OSX
    return false;
#else
    return true;
#endif
  }
 private:
#if TARGET_OS_OSX
  CGLContextObj context_ = nullptr;
#else
  __strong EAGLContext* context_ = nil;
#endif
};
template<typename T> struct CFValue {
  T value = nullptr;
  explicit CFValue(T v) : value(v) {}
  ~CFValue() { if (value) CFRelease(value); }
  CFValue(const CFValue&) = delete;
};
[[maybe_unused]] MilkRustImage DecodeImage(const std::filesystem::path& path) {
  @autoreleasepool {
    const auto length = std::filesystem::file_size(path);
    if (!length || length > 16*1024*1024) throw std::runtime_error("Texture exceeds its encoded byte budget.");
    std::ifstream file(path, std::ios::binary); std::vector<uint8_t> bytes(static_cast<size_t>(length));
    if (!file.read(reinterpret_cast<char*>(bytes.data()), static_cast<std::streamsize>(bytes.size())) || file.peek() != EOF)
      throw std::runtime_error("Texture changed while reading.");
    NSData* data = [NSData dataWithBytesNoCopy:bytes.data() length:bytes.size() freeWhenDone:NO];
    CFValue<CGImageSourceRef> source(CGImageSourceCreateWithData((__bridge CFDataRef)data,
        (__bridge CFDictionaryRef)@{(id)kCGImageSourceShouldCache:@NO}));
    if (!source.value) throw std::runtime_error("ImageIO could not read this texture.");
    CFValue<CFDictionaryRef> properties(CGImageSourceCopyPropertiesAtIndex(source.value, 0, nullptr));
    NSDictionary* metadata = (__bridge NSDictionary*)properties.value;
    const auto width = [metadata[(id)kCGImagePropertyPixelWidth] unsignedLongLongValue];
    const auto height = [metadata[(id)kCGImagePropertyPixelHeight] unsignedLongLongValue];
    if (!width || !height || width > 4096 || height > 4096 || width*height > 8*1024*1024)
      throw std::runtime_error("Texture dimensions exceed the decoded image budget.");
    CFValue<CGImageRef> image(CGImageSourceCreateImageAtIndex(source.value, 0, nullptr));
    if (!image.value || CGImageGetWidth(image.value) != width || CGImageGetHeight(image.value) != height)
      throw std::runtime_error("Texture dimensions changed during decode.");
    MilkRustImage output; output.width = static_cast<uint32_t>(width); output.height = static_cast<uint32_t>(height);
    output.rgba.resize(static_cast<size_t>(width*height*4));
    CFValue<CGColorSpaceRef> space(CGColorSpaceCreateDeviceRGB());
    CFValue<CGContextRef> bitmap(CGBitmapContextCreate(output.rgba.data(), width, height, 8, width*4, space.value,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big));
    if (!bitmap.value) throw std::runtime_error("Could not allocate a bounded image decoder.");
    CGContextTranslateCTM(bitmap.value, 0, height); CGContextScaleCTM(bitmap.value, 1, -1);
    CGContextDrawImage(bitmap.value, CGRectMake(0, 0, width, height), image.value);
    // Core Graphics emits premultiplied RGBA; the engine accepts straight RGBA.
    for (size_t i=0; i<output.rgba.size(); i+=4) {
      const unsigned alpha = output.rgba[i+3];
      for (size_t c=0; c<3; ++c) output.rgba[i+c] = alpha ? static_cast<uint8_t>(std::min(255u, (output.rgba[i+c]*255u+alpha/2)/alpha)) : 0;
    }
    return output;
  }
}
struct AppleFrames {
  std::mutex mutex; CVPixelBufferRef latest = nullptr;
  ~AppleFrames() { if (latest) CVPixelBufferRelease(latest); }
};
void Publish(const std::shared_ptr<AppleFrames>& slot, const NativeFrame& frame) {
  @autoreleasepool {
    CVPixelBufferRef buffer = nullptr;
    NSDictionary* attrs = @{(id)kCVPixelBufferIOSurfacePropertiesKey:@{}};
    if (CVPixelBufferCreate(kCFAllocatorDefault, frame.width, frame.height, kCVPixelFormatType_32BGRA,
        (__bridge CFDictionaryRef)attrs, &buffer) != kCVReturnSuccess) throw std::runtime_error("Could not allocate a Flutter pixel buffer.");
    CFValue<CVPixelBufferRef> keep(buffer);
    if (CVPixelBufferLockBaseAddress(buffer, 0) != kCVReturnSuccess) throw std::runtime_error("Could not lock the Flutter pixel buffer.");
    auto* pixels = static_cast<uint8_t*>(CVPixelBufferGetBaseAddress(buffer));
    const auto stride = CVPixelBufferGetBytesPerRow(buffer);
    for (uint32_t y=0; y<frame.height; ++y) for (uint32_t x=0; x<frame.width; ++x) {
      const auto* src = frame.rgba.data()+(static_cast<size_t>(y)*frame.width+x)*4;
      auto* dst = pixels+y*stride+x*4; dst[0]=src[2]; dst[1]=src[1]; dst[2]=src[0]; dst[3]=255;
    }
    CVPixelBufferUnlockBaseAddress(buffer, 0);
    std::lock_guard<std::mutex> lock(slot->mutex);
    if (slot->latest) CVPixelBufferRelease(slot->latest);
    slot->latest = CVPixelBufferRetain(buffer);
  }
}
void SetError(NSError** error, const std::exception& ex) {
  if (error) *error = [NSError errorWithDomain:@"MilkRust" code:1 userInfo:@{NSLocalizedDescriptionKey:
      [NSString stringWithUTF8String:ex.what()] ?: @"Native renderer failed"}];
}
}
BOOL PlezyVisualizationTapAvailable() { return Tap().available(); }
int PlezyVisualizationTapEnable(void* player, BOOL enabled) {
  return player && Tap().available() ? Tap().enable(static_cast<mpv_handle*>(player), enabled ? 1 : 0) : MPV_PLEZY_AUDIO_UNSUPPORTED;
}
int PlezyVisualizationTapRead(void* player, double pts, void* output, size_t size) {
  return player && std::isfinite(pts) && size == sizeof(mpv_plezy_audio_block) && Tap().available()
      ? Tap().read(static_cast<mpv_handle*>(player), pts, static_cast<mpv_plezy_audio_block*>(output), size) : (std::isfinite(pts) ? MPV_PLEZY_AUDIO_UNSUPPORTED : 0);
}
BOOL PlezySubtitlePcmCaptureAvailable(void) { return Tap().subtitle_available(); }
int PlezySubtitlePcmCaptureEnable(void* player, BOOL enabled) {
  return player && Tap().subtitle_available()
      ? Tap().enable(static_cast<mpv_handle*>(player), enabled ? 1 : 0) : MPV_PLEZY_AUDIO_UNSUPPORTED;
}
int PlezySubtitlePcmCaptureReadNext(void* player, double* pts, uint32_t* frames, uint32_t* sample_rate,
                                    uint32_t* channels, uint32_t* dropped_frames, void* samples,
                                    size_t sample_capacity) {
  if (!player || !pts || !frames || !sample_rate || !channels || !dropped_frames || !samples ||
      !Tap().subtitle_available()) return MPV_PLEZY_AUDIO_UNSUPPORTED;
  mpv_plezy_audio_block block{};
  const int result = Tap().read_next(static_cast<mpv_handle*>(player), &block, sizeof(block));
  if (result <= 0) return result;
  if (!std::isfinite(block.pts) || block.frames == 0 || block.frames > MPV_PLEZY_AUDIO_TAP_FRAMES ||
      block.sample_rate == 0 || block.channels == 0 || block.channels > MPV_PLEZY_AUDIO_TAP_CHANNELS)
    return MPV_PLEZY_AUDIO_UNSUPPORTED;
  const size_t sample_bytes = static_cast<size_t>(block.frames) * block.channels * sizeof(float);
  if (sample_bytes > sample_capacity) return MPV_PLEZY_AUDIO_UNSUPPORTED;
  std::memcpy(samples, block.samples, sample_bytes);
  *pts = block.pts;
  *frames = block.frames;
  *sample_rate = block.sample_rate;
  *channels = block.channels;
  *dropped_frames = block.dropped_frames;
  return 1;
}
@implementation PlezyMilkRustHost {
  std::unique_ptr<NativeWorker> _worker;
  std::shared_ptr<AppleFrames> _frames;
}
+ (NSString*)dependencyError {
#if TARGET_OS_OSX
  const auto reason = IsolatedRenderBackend::DependencyError();
#else
  const auto reason = MilkRustApi::Shared().error;
#endif
  return [NSString stringWithUTF8String:reason.c_str()] ?: @"Native engine unavailable";
}
- (instancetype)initWithAudioReader:(int (^)(void*, size_t))reader frameAvailable:(void (^)(void))available error:(NSError**)error {
  self = [super init]; if (!self) return nil;
  try {
    NSString* unavailable = [PlezyMilkRustHost dependencyError];
    if (unavailable.length) throw std::runtime_error(unavailable.UTF8String);
    _frames = std::make_shared<AppleFrames>(); auto slot = _frames;
    _worker = std::make_unique<NativeWorker>(
#if TARGET_OS_OSX
        [] { return std::make_unique<IsolatedRenderBackend>(); },
#else
        [] { return std::make_unique<AppleContext>(); }, DecodeImage,
#endif
        [reader](mpv_plezy_audio_block* block) { return reader(block, sizeof(*block)); },
        [slot, available](std::shared_ptr<const NativeFrame> frame) { Publish(slot, *frame); available(); });
  } catch (const std::exception& ex) { SetError(error, ex); return nil; }
  return self;
}
- (BOOL)loadPreset:(NSString*)path root:(NSString*)root transitionSeconds:(double)transitionSeconds
             error:(NSError**)error {
  try { if (!_worker) throw std::runtime_error("Visualization session has ended.");
    _worker->Load(path.UTF8String, root.UTF8String, transitionSeconds); return YES;
  } catch (const std::exception& ex) { SetError(error, ex); return NO; }
}
- (void)resizeWidth:(NSInteger)width height:(NSInteger)height {
  if (_worker && width >= 1 && height >= 1 && width <= 16384 && height <= 16384) _worker->Resize(static_cast<int>(width), static_cast<int>(height));
}
- (void)setMouseState:(BOOL)down x:(double)x y:(double)y dx:(double)dx dy:(double)dy {
  if (_worker) _worker->SetMouseState(down, x, y, dx, dy);
}
- (void)setPaused:(BOOL)paused { if (_worker) _worker->Pause(paused); }
- (NSDictionary<NSString*,id>*)status {
  if (!_worker) return @{@"state":@"disposed", @"hasFrame":@NO};
  const auto s = _worker->Status();
  return @{@"state":[NSString stringWithUTF8String:s.state.c_str()], @"reason":[NSString stringWithUTF8String:s.reason.c_str()],
      @"hasFrame":@(s.has_frame), @"width":@(s.width), @"height":@(s.height), @"droppedFrames":@(s.dropped), @"engine":@"milkrust"};
}
- (CVPixelBufferRef)copyPixelBuffer {
  const auto slot = _frames; if (!slot) return nullptr;
  std::lock_guard<std::mutex> lock(slot->mutex);
  return slot->latest ? CVPixelBufferRetain(slot->latest) : nullptr;
}
- (void)close { _worker.reset(); /* Frame leases remain valid through texture unregister. */ }
- (void)dealloc { [self close]; }
@end
