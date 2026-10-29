// Copyright 2022 Samsung Electronics Co., Ltd. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef FLUTTER_PLUGIN_MEDIA_PLAYER_H_
#define FLUTTER_PLUGIN_MEDIA_PLAYER_H_

#include <flutter/plugin_registrar.h>
#include <player.h>

#include <atomic>
#include <condition_variable>
#include <deque>
#include <memory>
#include <mutex>
#include <string>
#include <utility>
#include <vector>

#include "drm_manager.h"
#include "ftpw_video_player_videohole.h"
#include "video_player.h"
#include "visualizer_pcm.h"

namespace video_player_videohole_tizen {

class MediaPlayer : public VideoPlayer {
 public:
  explicit MediaPlayer(flutter::BinaryMessenger *messenger,
                       FlutterDesktopViewRef flutter_view);
  ~MediaPlayer();

  int64_t Create(const std::string &uri, const CreateMessage &create_message,
                 bool reuse_existing_id = false) override;
  int Prepare() override;
  void Dispose() override;

  void SetDisplayRoi(int32_t x, int32_t y, int32_t width,
                     int32_t height) override;
  bool Play() override;
  bool Pause() override;
  bool SetLooping(bool is_looping) override;
  bool SetVolume(double volume) override;
  bool SetPlaybackSpeed(double speed) override;
  bool SeekTo(int64_t position, SeekCompletedCallback callback) override;
  int64_t GetPosition() override;
  std::pair<int64_t, int64_t> GetDuration() override;
  void GetVideoSize(int32_t *width, int32_t *height) override;
  bool IsReady() override;
  flutter::EncodableList GetTrackInfo(std::string track_type) override;
  bool SetTrackSelection(int32_t track_id, std::string track_type) override;
  bool Suspend() override;
  bool Restore(const CreateMessage *restore_message,
               int64_t resume_time) override;
  bool SetDisplayRotate(int64_t rotation) override;
  bool SubtitlePcmCaptureAvailable() const override;
  bool SetSubtitlePcmCaptureEnabled(bool enabled) override;
  std::string DrainSubtitlePcmCaptureJson() override;
  std::shared_ptr<VisualizerPcm> VisualizationPcm() const override { return pcm_; }

 private:
  std::pair<int64_t, int64_t> GetLiveDuration();
  bool IsLive();
  bool SetDisplay();
  bool ConfigureSubtitlePcmCapture();
  void ClearSubtitlePcmCapture();
  void WaitForAudioCallbacks();
  bool SetDrm(const std::string &uri, int drm_type,
              const std::string &license_server_url);
  bool StopAndDestroy();
  bool RestorePlayer(const CreateMessage *restore_message, int64_t resume_time);
  void OnRestoreCompleted();

  static void OnPrepared(void *user_data);
  static void OnBuffering(int percent, void *user_data);
  static void OnSeekCompleted(void *user_data);
  static void OnPlayCompleted(void *user_data);
  static void OnInterrupted(player_interrupted_code_e code, void *user_data);
  static void OnError(int error_code, void *user_data);
  static void OnSubtitleUpdated(unsigned long duration, char *text,
                                void *user_data);
  static void OnAudioPcmDecoded(media_packet_h packet, void *user_data);
  static bool OnDrmSecurityInitComplete(int *drm_handle, unsigned int length,
                                        unsigned char *pssh_data,
                                        void *user_data);
  static int OnDrmUpdatePsshData(drm_init_data_type init_type, void *data,
                                 int data_length, void *user_data);

  player_h player_ = nullptr;
  bool audio_only_ = false;
  std::shared_ptr<VisualizerPcm> pcm_;
  std::unique_ptr<DrmManager> drm_manager_;
  bool is_buffering_ = false;
  SeekCompletedCallback on_seek_completed_;
  bool is_seeking_ = false;
  std::string url_;
  CreateMessage create_message_;
  player_state_e pre_state_;
  int64_t pre_playing_time_;
  int32_t pre_display_roi_x_ = 0;
  int32_t pre_display_roi_y_ = 0;
  int32_t pre_display_roi_width_ = 1;
  int32_t pre_display_roi_height_ = 1;
  struct CapturedAudioPacket {
    uint64_t presentation_time_us = 0;
    std::vector<uint8_t> pcm;
  };
  static constexpr size_t kSubtitlePcmCaptureMaxBytes = 768 * 1024;
  static constexpr int kSubtitlePcmSampleRate = 16000;
  std::atomic<bool> subtitle_pcm_capture_available_{false};
  std::atomic<bool> subtitle_pcm_capture_enabled_{false};
  bool subtitle_pcm_callback_registered_ = false;
  mutable std::mutex subtitle_pcm_mutex_;
  std::condition_variable subtitle_pcm_callbacks_idle_;
  std::deque<CapturedAudioPacket> subtitle_pcm_packets_;
  size_t subtitle_pcm_bytes_ = 0;
  size_t audio_callbacks_active_ = 0;
};

}  // namespace video_player_videohole_tizen

#endif  // FLUTTER_PLUGIN_MEDIA_PLAYER_H_
