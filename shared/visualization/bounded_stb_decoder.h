// SPDX-License-Identifier: AGPL-3.0-only
#pragma once
// Include in ONE translation unit per host. The pinned decoder's symbols are
// private; every allocation (including compressed-image scratch) is bounded.
#include "milkrust_engine.h"
#include <cstddef>
#include <cstdlib>
#include <cstring>
#include <memory>

namespace plezy::visualization::image_detail {
constexpr size_t kScratchLimit = 96 * 1024 * 1024;
inline thread_local size_t allocated = 0;
struct alignas(std::max_align_t) Header { size_t size; };
inline void* Allocate(size_t size) noexcept {
  if (size > kScratchLimit || allocated > kScratchLimit - size) return nullptr;
  auto* header = static_cast<Header*>(std::malloc(sizeof(Header) + size));
  if (!header) return nullptr;
  header->size = size; allocated += size; return header + 1;
}
inline void Free(void* pointer) noexcept {
  if (!pointer) return;
  auto* header = static_cast<Header*>(pointer) - 1;
  allocated -= header->size; std::free(header);
}
inline void* Reallocate(void* pointer, size_t size) noexcept {
  if (!pointer) return Allocate(size);
  auto* header = static_cast<Header*>(pointer) - 1;
  if (size > kScratchLimit || allocated - header->size > kScratchLimit - size) return nullptr;
  const size_t previous = header->size;
  auto* replacement = static_cast<Header*>(std::realloc(header, sizeof(Header) + size));
  if (!replacement) return nullptr;
  replacement->size = size; allocated = allocated - previous + size;
  return replacement + 1;
}
}  // namespace plezy::visualization::image_detail

#define STB_IMAGE_IMPLEMENTATION
#define STB_IMAGE_STATIC
#define STBI_NO_STDIO
#define STBI_ONLY_PNG
#define STBI_ONLY_JPEG
#define STBI_ONLY_BMP
#define STBI_ONLY_TGA
#define STBI_ONLY_GIF
#define STBI_MAX_DIMENSIONS 4096
#define STBI_MALLOC(size) plezy::visualization::image_detail::Allocate(size)
#define STBI_REALLOC(pointer, size) plezy::visualization::image_detail::Reallocate(pointer, size)
#define STBI_FREE(pointer) plezy::visualization::image_detail::Free(pointer)
#include "third_party/stb/stb_image.h"
#undef STB_IMAGE_IMPLEMENTATION
#undef STB_IMAGE_STATIC
#undef STBI_NO_STDIO
#undef STBI_ONLY_PNG
#undef STBI_ONLY_JPEG
#undef STBI_ONLY_BMP
#undef STBI_ONLY_TGA
#undef STBI_ONLY_GIF
#undef STBI_MAX_DIMENSIONS
#undef STBI_MALLOC
#undef STBI_REALLOC
#undef STBI_FREE

namespace plezy::visualization {
inline MilkRustImage DecodeBoundedImage(const std::filesystem::path& path) {
  const auto length = std::filesystem::file_size(path);
  if (!length || length > 16 * 1024 * 1024) throw std::runtime_error("Texture exceeds the encoded image budget.");
  std::vector<uint8_t> bytes(static_cast<size_t>(length));
  std::ifstream file(path, std::ios::binary);
  if (!file.read(reinterpret_cast<char*>(bytes.data()), static_cast<std::streamsize>(bytes.size())) || file.peek() != EOF)
    throw std::runtime_error("Texture changed while loading.");
  int width = 0, height = 0, channels = 0;
  if (!stbi_info_from_memory(bytes.data(), static_cast<int>(bytes.size()), &width, &height, &channels) ||
      width < 1 || height < 1 || width > 4096 || height > 4096 || uint64_t(width) * height > 8 * 1024 * 1024)
    throw std::runtime_error("Texture format or dimensions are unsupported (PNG, JPEG, BMP, GIF and TGA only).");
  const int expected_width = width, expected_height = height;
  std::unique_ptr<stbi_uc, decltype(&stbi_image_free)> decoded(
      stbi_load_from_memory(bytes.data(), static_cast<int>(bytes.size()), &width, &height, &channels, 4), stbi_image_free);
  if (!decoded || width != expected_width || height != expected_height)
    throw std::runtime_error("Texture decode failed or exceeded the 96 MiB decoder budget.");
  MilkRustImage image; image.width = width; image.height = height;
  image.rgba.assign(decoded.get(), decoded.get() + static_cast<size_t>(width) * height * 4);
  return image;
}
}  // namespace plezy::visualization
