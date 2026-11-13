// SPDX-License-Identifier: GPL-3.0-or-later
#import <XCTest/XCTest.h>
#include <mutex>
#include "../steam/tests/red_h264.h"
#include "SteamAppleSink.h"
#include "SteamMetalPyrowave.h"

@interface SteamAppleSinkTests : XCTestCase
@end
@implementation SteamAppleSinkTests
- (void)testRealH264PixelsAndTeardown {
  std::mutex mutex;
  XCTestExpectation* ready = [self expectationWithDescription:@"real H.264 decode callback"];
  bool failed = false, presented = false, red = false, completed = false, completedShown = false;
  bool notified = false;
  // Called under mutex. Any terminal callback wakes the test exactly once;
  // XCTest's wait keeps the main run loop available to VideoToolbox startup.
  auto notify = [&] {
    if (!notified) {
      notified = true;
      [ready fulfill];
    }
  };
  plezy::steam::AppleSink sink(
      [&](CVPixelBufferRef image, uint32_t id) {
        bool valid = id == 7 && CVPixelBufferGetWidth(image) == 64 && CVPixelBufferGetHeight(image) == 64;
        if (CVPixelBufferLockBaseAddress(image, kCVPixelBufferLock_ReadOnly) == kCVReturnSuccess) {
          auto* pixel = static_cast<const uint8_t*>(CVPixelBufferGetBaseAddress(image));
          // H.264 carries no alpha channel; VideoToolbox's unused BGRA byte is unspecified.
          valid = valid && pixel && pixel[0] < 50 && pixel[1] < 50 && pixel[2] > 200;
          CVPixelBufferUnlockBaseAddress(image, kCVPixelBufferLock_ReadOnly);
        } else
          valid = false;
        {
          std::lock_guard<std::mutex> lock(mutex);
          red = valid;
          presented = true;
          notify();
        }
        return true;
      },
      [&](uint32_t id, bool shown) {
        if (id != 7) return;
        {
          std::lock_guard<std::mutex> lock(mutex);
          completed = true;
          completedShown = shown;
          notify();
        }
      },
      [&](bool) {
        {
          std::lock_guard<std::mutex> lock(mutex);
          failed = true;
          notify();
        }
      });
  XCTAssertFalse(sink.video(99, 64, 64, nullptr, 0));
  XCTAssertFalse(sink.video(IHS_StreamVideoCodecH264, 100000, 64, nullptr, 0));
  XCTAssertFalse(sink.frame(redH264, 8 * 1024 * 1024 + 1, 1, true));
  XCTAssertTrue(sink.video(IHS_StreamVideoCodecH264, 64, 64, nullptr, 0));
  XCTAssertTrue(sink.frame(redH264, sizeof(redH264), 7, true));
  // The hosted iOS simulator can take longer to schedule its first VideoToolbox callback.
  [self waitForExpectations:@[ready] timeout:30];
  {
    std::lock_guard<std::mutex> lock(mutex);
    XCTAssertFalse(failed);
    XCTAssertTrue(
        presented, "No decoded frame arrived (completed=%d, displayed=%d, decoderKind=%d)", completed, completedShown,
        sink.decoderKind());
    XCTAssertTrue(red, "The decoded frame did not match the expected red pixels");
    XCTAssertFalse(completed, "The frame completed before presentation (displayed=%d)", completedShown);
  }
  sink.close();
  sink.close();
  XCTAssertFalse(sink.frame(redH264, sizeof(redH264), 8, true));
}
- (void)testMetalPyrowave420And444ColorAndHdrRejection {
  XCTSkipIf(!plezy::steam::MetalPyrowave::supported(), @"Requires an Apple7-family GPU");
  for (bool fullChroma : {false, true}) {
    plezy::steam::MetalPyrowave decoder;
    XCTAssertTrue(decoder.start(64, 64, nullptr, 0));
    // A sequence with no nonzero wavelet blocks reconstructs uniform gray.
    const uint32_t words[] = {63u | (63u << 14) | (1u << 31), fullChroma ? (1u << 26) : 0};
    uint8_t encoded[8];
    for (size_t i = 0; i < 8; ++i) encoded[i] = uint8_t(words[i / 4] >> (8 * (i % 4)));
    CVPixelBufferRef image = nullptr;
    XCTAssertTrue(decoder.decode(encoded, sizeof(encoded), &image) == plezy::steam::PyrowaveDecodeStatus::frame);
    XCTAssertTrue(image != nullptr);
    if (image) {
      XCTAssertEqual(CVPixelBufferGetWidth(image), size_t(64));
      XCTAssertEqual(CVPixelBufferLockBaseAddress(image, kCVPixelBufferLock_ReadOnly), kCVReturnSuccess);
      const auto* pixel = static_cast<const uint8_t*>(CVPixelBufferGetBaseAddress(image));
      XCTAssertTrue(
          pixel && pixel[0] >= 120 && pixel[0] <= 136 && pixel[1] >= 120 && pixel[1] <= 136 && pixel[2] >= 120 &&
          pixel[2] <= 136 && pixel[3] == 255);
      CVPixelBufferUnlockBaseAddress(image, kCVPixelBufferLock_ReadOnly);
      CVPixelBufferRelease(image);
    }
    encoded[7] |= 0x10;  // HDR must not be clipped into the SDR texture.
    XCTAssertTrue(decoder.decode(encoded, sizeof(encoded), &image) == plezy::steam::PyrowaveDecodeStatus::invalid);
    XCTAssertTrue(image == nullptr);
    decoder.reset();
    decoder.reset();
  }
}
- (void)testMetalHdrRetainsDeepPixelsAndRejectsColorChanges {
  XCTSkipIf(!plezy::steam::MetalPyrowave::supported(), @"Requires an Apple7-family GPU");
  for (bool fullChroma : {false, true}) {
    plezy::steam::MetalPyrowave decoder;
    XCTAssertTrue(decoder.start(64, 64, nullptr, 0, true));
    const uint32_t words[] = {63u | (63u << 14) | (1u << 31), (0x38u << 24) | (fullChroma ? (1u << 26) : 0)};
    uint8_t encoded[8];
    for (size_t i = 0; i < 8; ++i) encoded[i] = uint8_t(words[i / 4] >> (8 * (i % 4)));
    CVPixelBufferRef image = nullptr;
    XCTAssertTrue(decoder.decode(encoded, sizeof(encoded), &image) == plezy::steam::PyrowaveDecodeStatus::frame);
    XCTAssertTrue(image != nullptr);
    XCTAssertTrue(decoder.hdr10());
    if (image) {
      XCTAssertEqual(CVPixelBufferGetPixelFormatType(image), kCVPixelFormatType_64RGBAHalf);
      XCTAssertEqual(CVPixelBufferGetBytesPerRow(image) >= 64 * 8, true);
      XCTAssertEqual(CVPixelBufferLockBaseAddress(image, kCVPixelBufferLock_ReadOnly), kCVReturnSuccess);
      const auto* pixel = static_cast<const uint16_t*>(CVPixelBufferGetBaseAddress(image));
      // Half-float gray is approximately 0x3800, alpha is exactly 1.0.
      XCTAssertTrue(pixel && pixel[0] >= 0x3700 && pixel[0] <= 0x3900 && pixel[3] == 0x3c00);
      CVPixelBufferUnlockBaseAddress(image, kCVPixelBufferLock_ReadOnly);
      CVPixelBufferRelease(image);
    }
    encoded[7] &= ~0x38u;
    XCTAssertTrue(decoder.decode(encoded, sizeof(encoded), &image) == plezy::steam::PyrowaveDecodeStatus::invalid);
    XCTAssertTrue(image == nullptr);
  }
}
@end
