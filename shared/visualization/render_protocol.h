// SPDX-License-Identifier: AGPL-3.0-only
#pragma once
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>
#include <stdexcept>
#include <string>
#include <vector>

namespace plezy::visualization::render_protocol {
constexpr uint32_t kMagic = 0x50565231;
constexpr uint32_t kVersion = 2;
constexpr size_t kHeaderSize = 20;
constexpr uint32_t kMaxMessage = 4 * 1024 * 1024;
constexpr uint32_t kMaxWidth = 1280, kMaxHeight = 720;
constexpr uint32_t kMaxPcmFrames = 4096;
constexpr uint32_t kCanPresent = 1;
constexpr uint32_t kReply = 0x80000000;
enum class Command : uint32_t { Hello = 1, Reset, Load, Pcm, Capture, Pause, Mouse, Present };
enum class Backend : uint32_t { MilkRust = 0, ProjectM = 1 };
using Bytes = std::vector<uint8_t>;
inline void U32(Bytes& out, uint32_t value) {
  for (unsigned shift = 0; shift < 32; shift += 8) out.push_back(static_cast<uint8_t>(value >> shift));
}
inline void U64(Bytes& out, uint64_t value) {
  U32(out, static_cast<uint32_t>(value)); U32(out, static_cast<uint32_t>(value >> 32));
}
inline void Float(Bytes& out, float value) {
  static_assert(sizeof(float) == 4 && std::numeric_limits<float>::is_iec559, "IEEE float required");
  uint32_t bits; std::memcpy(&bits, &value, sizeof(bits)); U32(out, bits);
}
inline void Double(Bytes& out, double value) {
  static_assert(sizeof(double) == 8 && std::numeric_limits<double>::is_iec559, "IEEE double required");
  uint64_t bits; std::memcpy(&bits, &value, sizeof(bits)); U64(out, bits);
}
inline void Text(Bytes& out, const std::string& text, size_t maximum = 32768) {
  if (text.size() > maximum || text.find('\0') != std::string::npos)
    throw std::runtime_error("Invalid visualization protocol string.");
  U32(out, static_cast<uint32_t>(text.size())); out.insert(out.end(), text.begin(), text.end());
}
class Reader {
  const Bytes& data_;
  size_t offset_ = 0;
 public:
  explicit Reader(const Bytes& data) : data_(data) {}
  uint32_t U32() {
    if (data_.size() - offset_ < 4) throw std::runtime_error("Truncated visualization message.");
    uint32_t value = 0;
    for (unsigned shift = 0; shift < 32; shift += 8) value |= uint32_t(data_[offset_++]) << shift;
    return value;
  }
  uint64_t U64() { const uint64_t low = U32(); return low | (uint64_t(U32()) << 32); }
  float Float() { const auto bits = U32(); float value; std::memcpy(&value, &bits, sizeof(value)); return value; }
  double Double() { const auto bits = U64(); double value; std::memcpy(&value, &bits, sizeof(value)); return value; }
  std::string Text(size_t maximum = 32768) {
    const auto size = U32();
    if (size > maximum || size > data_.size() - offset_) throw std::runtime_error("Invalid visualization string length.");
    std::string value(data_.begin() + offset_, data_.begin() + offset_ + size); offset_ += size;
    if (value.find('\0') != std::string::npos) throw std::runtime_error("Visualization strings cannot contain NUL.");
    return value;
  }
  void End() const {
    if (offset_ != data_.size()) throw std::runtime_error("Unexpected visualization payload bytes.");
  }
};
struct Header { uint32_t command, sequence, size; };
inline Bytes EncodeHeader(uint32_t command, uint32_t sequence, size_t size) {
  if (size > kMaxMessage || !sequence) throw std::runtime_error("Visualization protocol limit exceeded.");
  Bytes bytes; bytes.reserve(kHeaderSize);
  U32(bytes, kMagic); U32(bytes, kVersion); U32(bytes, command); U32(bytes, sequence); U32(bytes, static_cast<uint32_t>(size));
  return bytes;
}
inline Header DecodeHeader(const Bytes& bytes) {
  Reader reader(bytes);
  if (reader.U32() != kMagic || reader.U32() != kVersion) throw std::runtime_error("Visualization helper protocol differs.");
  Header header{reader.U32(), reader.U32(), reader.U32()}; reader.End();
  const auto command = header.command & ~kReply;
  if (!header.sequence || header.size > kMaxMessage || command < uint32_t(Command::Hello) || command > uint32_t(Command::Present))
    throw std::runtime_error("Invalid visualization helper header.");
  return header;
}
inline size_t FrameBytes(uint32_t width, uint32_t height) {
  if (!width || !height || width > kMaxWidth || height > kMaxHeight)
    throw std::runtime_error("Visualization helper frame exceeds the 1280 by 720 limit.");
  return size_t(width) * height * 4;
}
}  // namespace plezy::visualization::render_protocol
