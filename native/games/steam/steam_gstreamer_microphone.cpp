// SPDX-License-Identifier: GPL-3.0-or-later
#include <gst/app/gstappsink.h>

#include <algorithm>
#include <array>
#include <cstring>
#include <thread>

#include "steam_microphone_capture.h"

namespace plezy::steam {
bool startMicrophoneCapture(std::shared_ptr<Runtime> runtime) {
  if (!runtime) return false;
  const auto lease = runtime->beginMicrophone();
  if (!lease) return false;
  try {
    std::thread([runtime, lease] {
      GstElement* pipeline = nullptr;
      GstElement* sink = nullptr;
      std::array<int16_t, 11520> pcm{};
      if (gst_init_check(nullptr, nullptr, nullptr) && runtime->microphoneCurrent(lease.epoch)) {
        // Only fixed app-owned elements and validated numeric formats enter the
        // pipeline. Never accept a launch string or device path from the host.
        const std::string launch =
            "autoaudiosrc ! audioconvert ! audioresample ! audio/x-raw,format=S16LE,layout=interleaved,rate=" +
            std::to_string(lease.rate) + ",channels=" + std::to_string(lease.channels) +
            " ! appsink name=mic max-buffers=3 drop=true sync=false";
        GError* error = nullptr;
        pipeline = gst_parse_launch(launch.c_str(), &error);
        const bool parsed = !error;
        if (error) g_error_free(error);
        if (pipeline && parsed) sink = gst_bin_get_by_name(GST_BIN(pipeline), "mic");
        if (sink && runtime->microphoneCurrent(lease.epoch) &&
            gst_element_set_state(pipeline, GST_STATE_PLAYING) != GST_STATE_CHANGE_FAILURE) {
          auto last = std::chrono::steady_clock::now();
          while (runtime->microphoneCurrent(lease.epoch)) {
            GstSample* sample = gst_app_sink_try_pull_sample(GST_APP_SINK(sink), 20 * GST_MSECOND);
            if (!sample) {
              if (gst_app_sink_is_eos(GST_APP_SINK(sink)) ||
                  std::chrono::steady_clock::now() - last > std::chrono::seconds(3))
                break;
              continue;
            }
            last = std::chrono::steady_clock::now();
            GstBuffer* buffer = gst_sample_get_buffer(sample);
            GstMapInfo map{};
            bool ok = buffer && gst_buffer_map(buffer, &map, GST_MAP_READ);
            if (ok) {
              ok = map.size && map.size <= pcm.size() * sizeof(int16_t) && map.size % (2 * lease.channels) == 0;
              if (ok) {
                // Read the negotiated little-endian format without alignment
                // assumptions, including on a big-endian Linux host.
                for (size_t i = 0; i < map.size / 2; ++i)
                  pcm[i] = int16_t(uint16_t(map.data[i * 2]) | uint16_t(map.data[i * 2 + 1]) << 8);
                ok = runtime->microphonePcm(lease.epoch, pcm.data(), map.size / 2);
                pcm.fill(0);
              }
              gst_buffer_unmap(buffer, &map);
            }
            gst_sample_unref(sample);
            if (!ok) break;
          }
        }
      }
      if (pipeline) gst_element_set_state(pipeline, GST_STATE_NULL);
      if (sink) gst_object_unref(sink);
      if (pipeline) gst_object_unref(pipeline);
      pcm.fill(0);
      runtime->finishMicrophone(lease.epoch);
    }).detach();
  } catch (...) {
    runtime->finishMicrophone(lease.epoch);
    return false;
  }
  return true;
}
}  // namespace plezy::steam
