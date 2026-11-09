// SPDX-License-Identifier: AGPL-3.0-only
#pragma once
#include <cmath>
#include <cstdint>
#include <cstring>
#include <limits>
#include <stdexcept>
#include <string>
#include <vector>

namespace plezy::retro {
using Bytes = std::vector<uint8_t>;
constexpr uint32_t kMagic = 0x52545231, kVersion = 1, kReply = 0x80000000;
constexpr size_t kHeaderSize = 20, kMaximumState = 128 * 1024 * 1024;
constexpr size_t kMaximumMessage = kMaximumState + 65536;
constexpr uint32_t kMaximumDimension = 2048, kMaximumSamples = 32768;
enum class Command : uint32_t { Probe = 1, Open, Run, Buttons, Pause, Capture, Restore, Close };
inline void Check(bool value) {
  if (!value) throw std::runtime_error("Invalid emulator worker message");
}
inline void U32(Bytes& out, uint32_t value) {
  for (unsigned shift = 0; shift < 32; shift += 8) out.push_back(static_cast<uint8_t>(value >> shift));
}
inline void Double(Bytes& out, double value) {
  static_assert(sizeof(double) == 8 && std::numeric_limits<double>::is_iec559, "IEEE double required");
  uint64_t bits;
  std::memcpy(&bits, &value, sizeof(bits));
  U32(out, static_cast<uint32_t>(bits));
  U32(out, static_cast<uint32_t>(bits >> 32));
}
inline void Text(Bytes& out, const std::string& text, size_t maximum = 32768) {
  Check(text.size() <= maximum && text.find('\0') == std::string::npos);
  U32(out, static_cast<uint32_t>(text.size()));
  out.insert(out.end(), text.begin(), text.end());
}
class Reader {
  const Bytes& bytes_;
  size_t offset_ = 0;

 public:
  explicit Reader(const Bytes& bytes) : bytes_(bytes) {}
  uint32_t U32() {
    Check(bytes_.size() - offset_ >= 4);
    uint32_t value = 0;
    for (unsigned shift = 0; shift < 32; shift += 8) value |= uint32_t(bytes_[offset_++]) << shift;
    return value;
  }
  double Double() {
    const uint64_t low = U32();
    const uint64_t bits = low | (uint64_t(U32()) << 32);
    double value;
    std::memcpy(&value, &bits, sizeof(value));
    return value;
  }
  Bytes Data(size_t size) {
    Check(size <= bytes_.size() - offset_);
    Bytes out(bytes_.begin() + offset_, bytes_.begin() + offset_ + size);
    offset_ += size;
    return out;
  }
  std::string Text(size_t maximum = 32768) {
    const auto size = U32();
    Check(size <= maximum);
    const auto raw = Data(size);
    std::string out(raw.begin(), raw.end());
    Check(out.find('\0') == std::string::npos);
    return out;
  }
  void End() const { Check(offset_ == bytes_.size()); }
};
struct Header {
  uint32_t command, sequence, size;
};
inline Bytes HeaderBytes(uint32_t command, uint32_t sequence, size_t size) {
  Check(sequence && size <= kMaximumMessage);
  Bytes out;
  U32(out, kMagic);
  U32(out, kVersion);
  U32(out, command);
  U32(out, sequence);
  U32(out, static_cast<uint32_t>(size));
  return out;
}
inline Header ReadHeader(const Bytes& bytes) {
  Reader in(bytes);
  Check(in.U32() == kMagic && in.U32() == kVersion);
  Header header{in.U32(), in.U32(), in.U32()};
  in.End();
  const auto command = header.command & ~kReply;
  Check(header.sequence && header.size <= kMaximumMessage && command >= 1 && command <= uint32_t(Command::Close));
  return header;
}
inline size_t FrameSize(uint32_t width, uint32_t height) {
  Check(width <= kMaximumDimension && height <= kMaximumDimension && (width == 0) == (height == 0));
  return size_t(width) * height * 4;
}
}  // namespace plezy::retro
