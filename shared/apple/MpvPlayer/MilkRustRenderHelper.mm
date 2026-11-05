// SPDX-License-Identifier: AGPL-3.0-only
#import <Foundation/Foundation.h>
#import <TargetConditionals.h>
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>
#import <OpenGL/OpenGL.h>
#include "../../visualization/render_helper.h"
#include <dlfcn.h>
#include <cstring>

using namespace plezy::visualization;
namespace {
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
MilkRustImage DecodeImage(const std::filesystem::path& path) {
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
}
int main(int argc, char** argv) {
  if (argc != 3 || std::strcmp(argv[1], "--plezy-render-pipe") || std::strcmp(argv[2], "3")) return 64;
  @autoreleasepool {
    RunRenderHelper(3, [](render_protocol::Backend kind) {
      if (kind != render_protocol::Backend::MilkRust) throw std::runtime_error("This helper supports MilkRust.");
      return std::make_unique<LocalRenderBackend>(std::make_unique<AppleContext>(), DecodeImage);
    });
  }
}
