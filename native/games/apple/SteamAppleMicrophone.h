// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import <AVFoundation/AVFoundation.h>
#include <algorithm>
#include <array>
#include <deque>
#include <thread>
#include "steam_microphone_capture.h"

// Kept in the plugin's Objective-C++ translation unit so every Apple target,
// including tvOS, receives the same availability guards.
namespace plezy::steam {
#if !TARGET_OS_TV
namespace {
std::mutex appleMicrophoneDevice;
struct AppleMicrophoneQueue {
  std::mutex mutex;
  std::array<std::array<int16_t, 11520>, 3> samples{};
  std::array<size_t, 3> lengths{};
  unsigned read = 0, write = 0, count = 0;
  bool failed = false;
};
void captureAppleMicrophone(const std::shared_ptr<Runtime>& runtime, MicrophoneLease lease) {
  std::unique_lock<std::mutex> device(appleMicrophoneDevice, std::try_to_lock);
  if (!device.owns_lock() || !runtime->microphoneCurrent(lease.epoch) ||
      [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio] != AVAuthorizationStatusAuthorized)
    return;
#if !TARGET_OS_OSX
  AVAudioSession* session = [AVAudioSession sharedInstance];
  NSString* category = session.category;
  NSString* mode = session.mode;
  AVAudioSessionCategoryOptions options = session.categoryOptions;
  const AVAudioSessionCategoryOptions captureOptions = AVAudioSessionCategoryOptionAllowBluetooth |
                                                       AVAudioSessionCategoryOptionDefaultToSpeaker |
                                                       AVAudioSessionCategoryOptionMixWithOthers;
  if (![session setCategory:AVAudioSessionCategoryPlayAndRecord
                       mode:AVAudioSessionModeVoiceChat
                    options:captureOptions
                      error:nil])
    return;
#endif
  AVAudioEngine* engine = [AVAudioEngine new];
  bool installed = false;
  auto queue = std::make_shared<AppleMicrophoneQueue>();
  @try {
    AVAudioInputNode* input = engine.inputNode;
    AVAudioFormat* source = [input outputFormatForBus:0];
    AVAudioFormat* format = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatInt16
                                                             sampleRate:lease.rate
                                                               channels:lease.channels
                                                            interleaved:YES];
    AVAudioConverter* converter = source.sampleRate >= 8000 && source.channelCount > 0 && source.channelCount <= 8
                                      ? [[AVAudioConverter alloc] initFromFormat:source toFormat:format]
                                      : nil;
    AVAudioPCMBuffer* output = converter ? [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:5760] : nil;
    if (converter && output && runtime->microphoneCurrent(lease.epoch)) {
      [input installTapOnBus:0
                  bufferSize:512
                      format:source
                       block:^(AVAudioPCMBuffer* buffer, AVAudioTime*) {
                         // A real-time audio callback never waits for the encoder/network. Drop
                         // a block on contention and keep at most three bounded PCM blocks.
                         std::unique_lock<std::mutex> lock(queue->mutex, std::try_to_lock);
                         if (!lock.owns_lock() || queue->failed || queue->count == 3) return;
                         if (!buffer.frameLength || buffer.frameLength > 4096 ||
                             buffer.format.sampleRate != source.sampleRate ||
                             double(buffer.frameLength) * lease.rate / source.sampleRate + 32 > 5760) {
                           queue->failed = true;
                           return;
                         }
                         __block BOOL supplied = NO;
                         output.frameLength = 0;
                         NSError* error = nil;
                         AVAudioConverterOutputStatus status =
                             [converter convertToBuffer:output
                                                  error:&error
                                     withInputFromBlock:^AVAudioBuffer*(
                                         AVAudioPacketCount, AVAudioConverterInputStatus* inputStatus) {
                                       if (supplied) {
                                         *inputStatus = AVAudioConverterInputStatus_NoDataNow;
                                         return nil;
                                       }
                                       supplied = YES;
                                       *inputStatus = AVAudioConverterInputStatus_HaveData;
                                       return buffer;
                                     }];
                         if (error || status == AVAudioConverterOutputStatus_Error || !output.int16ChannelData) {
                           queue->failed = true;
                           return;
                         }
                         const size_t count = size_t(output.frameLength) * lease.channels;
                         if (count && count <= queue->samples[0].size()) {
                           std::copy_n(output.int16ChannelData[0], count, queue->samples[queue->write].data());
                           std::fill_n(output.int16ChannelData[0], count, 0);
                           queue->lengths[queue->write] = count;
                           queue->write = (queue->write + 1) % 3;
                           ++queue->count;
                         }
                       }];
      installed = true;
#if !TARGET_OS_OSX
      const bool sessionReady = [session setActive:YES error:nil];
#else
      const bool sessionReady = true;
#endif
      if (sessionReady && runtime->microphoneCurrent(lease.epoch) && [engine startAndReturnError:nil]) {
        std::array<int16_t, 11520> pcm{};
        auto last = std::chrono::steady_clock::now();
        while (runtime->microphoneCurrent(lease.epoch) && engine.running) {
          size_t count = 0;
          {
            std::lock_guard<std::mutex> lock(queue->mutex);
            if (queue->failed) break;
            if (queue->count) {
              count = queue->lengths[queue->read];
              std::copy_n(queue->samples[queue->read].data(), count, pcm.data());
              queue->samples[queue->read].fill(0);
              queue->read = (queue->read + 1) % 3;
              --queue->count;
            }
          }
          if (count) {
            const bool sent = runtime->microphonePcm(lease.epoch, pcm.data(), count);
            pcm.fill(0);
            if (!sent) break;
            last = std::chrono::steady_clock::now();
          } else {
            if (std::chrono::steady_clock::now() - last > std::chrono::seconds(3)) break;
            std::this_thread::sleep_for(std::chrono::milliseconds(5));
          }
        }
        pcm.fill(0);
      }
    }
  } @catch (NSException*) {
    // Device removal or an invalid hardware format is a muted/unavailable path.
  }
  [engine stop];
  if (installed) [engine.inputNode removeTapOnBus:0];
  {
    std::lock_guard<std::mutex> lock(queue->mutex);
    queue->failed = true;
    for (auto& samples : queue->samples) samples.fill(0);
  }
#if !TARGET_OS_OSX
  // Restore only the category we still own; never deactivate another player's
  // audio session or overwrite a category selected after recording began.
  if ([session.category isEqualToString:AVAudioSessionCategoryPlayAndRecord] &&
      [session.mode isEqualToString:AVAudioSessionModeVoiceChat] && session.categoryOptions == captureOptions)
    [session setCategory:category mode:mode options:options error:nil];
#endif
}
}  // namespace
#endif
inline bool startMicrophoneCapture(std::shared_ptr<Runtime> runtime) {
#if TARGET_OS_TV
  (void)runtime;
  return false;
#else
  if (!runtime) return false;
  const auto lease = runtime->beginMicrophone();
  if (!lease) return false;
  try {
    std::thread([runtime, lease] {
      @autoreleasepool {
        captureAppleMicrophone(runtime, lease);
      }
      runtime->finishMicrophone(lease.epoch);
    }).detach();
  } catch (...) {
    runtime->finishMicrophone(lease.epoch);
    return false;
  }
  return true;
#endif
}
}  // namespace plezy::steam
