// SPDX-License-Identifier: GPL-3.0-or-later
#include <gdk/gdkwayland.h>
#include <gtk/gtk.h>
#include <vulkan/vulkan.h>

// Pyrowave chooses its Vulkan ABI from the previously included headers.
#include <pyrowave.h>

#include <cassert>
#include <chrono>
#include <cstdio>
#include <thread>
#include <vector>

#include "steam_vulkan_presenter.h"
#include "wayland_video_surface.h"

using namespace plezy::steam;
namespace {
std::vector<uint8_t> encode(bool fullChroma) {
  pyrowave_device device = nullptr;
  pyrowave_encoder encoder = nullptr;
  assert(pyrowave_create_default_device(&device) == PYROWAVE_SUCCESS);
  pyrowave_encoder_create_info info{};
  info.device = device;
  info.width = info.height = 64;
  info.chroma = fullChroma ? PYROWAVE_CHROMA_SUBSAMPLING_444 : PYROWAVE_CHROMA_SUBSAMPLING_420;
  assert(pyrowave_encoder_create(&info, &encoder) == PYROWAVE_SUCCESS);
  std::vector<uint8_t> y(4096, 210), cb(4096, 96), cr(4096, 160);
  pyrowave_cpu_buffer input{};
  input.width = input.height = 64;
  input.format = fullChroma ? PYROWAVE_CPU_BUFFER_FORMAT_YUV444P : PYROWAVE_CPU_BUFFER_FORMAT_YUV420P;
  input.data[0] = y.data();
  input.data[1] = cb.data();
  input.data[2] = cr.data();
  for (int i = 0; i < 3; ++i) {
    input.row_stride_in_bytes[i] = i && !fullChroma ? 32 : 64;
    input.plane_size_in_bytes[i] = 4096;
  }
  pyrowave_rate_control rate{65536};
  assert(pyrowave_encoder_encode_cpu(encoder, &input, &rate) == PYROWAVE_SUCCESS);
  size_t count = 0;
  assert(pyrowave_encoder_compute_num_packets(encoder, 65536, &count) == PYROWAVE_SUCCESS && count == 1);
  std::vector<uint8_t> bytes(65536);
  pyrowave_packet packet{};
  assert(pyrowave_encoder_packetize(encoder, &packet, 65536, &count, bytes.data(), bytes.size()) == PYROWAVE_SUCCESS);
  assert(packet.offset == 0 && packet.size > 8 && packet.size <= bytes.size());
  bytes.resize(packet.size);
  pyrowave_encoder_destroy(encoder);
  pyrowave_device_destroy(device);
  return bytes;
}
void pump() {
  while (gtk_events_pending()) gtk_main_iteration_do(false);
}
void present(VulkanPresenter& renderer, mpv::WaylandVideoSurface& plane, const std::vector<uint8_t>& frame) {
  static uint32_t sequence = 0;
  auto fresh = frame;
  ++sequence;
  fresh[4] = sequence;
  fresh[5] = sequence >> 8;
  fresh[6] = sequence >> 16;
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(3);
  while (std::chrono::steady_clock::now() < deadline) {
    pump();
    if (plane.PreparePresent()) {
      auto result = renderer.present(fresh.data(), fresh.size(), plane.width(), plane.height());
      assert(result != PyrowaveDecodeStatus::invalid);
      const bool displayed = plane.CompletePresent(result == PyrowaveDecodeStatus::frame);
      if (displayed) return;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
  }
  assert(false && "native presentation timed out");
}
}  // namespace
int main(int argc, char** argv) {
  if (!gtk_init_check(&argc, &argv) || !GDK_IS_WAYLAND_DISPLAY(gdk_display_get_default())) return 127;
  auto* window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
  auto* view = gtk_drawing_area_new();
  gtk_widget_set_size_request(view, 320, 240);
  gtk_container_add(GTK_CONTAINER(window), view);
  gtk_widget_show_all(window);
  gdk_display_sync(gdk_display_get_default());
  pump();
  {
    mpv::WaylandVideoSurface plane;
    std::string error;
    assert(plane.Create(view, &error, true));
    plane.SetRect(0, 0, 64, 64, 1);
    plane.SetVisible(true);
    VulkanPresenter renderer;
    if (!renderer.open({GpuWindow::Kind::wayland, plane.native_display(), plane.native_surface()}, false)) {
      std::puts("SKIP: no supported hardware Vulkan device/surface (CPU Vulkan is not qualified)");
      return 127;
    }
    const auto frame420 = encode(false);
    const auto frame444 = encode(true);
    assert(!renderer.supportsHdr10());
    for (bool fullChroma : {false, true, false}) {
      auto frame = fullChroma ? frame444 : frame420;
      assert(renderer.configure(64, 64, nullptr, 0));
      present(renderer, plane, frame);
      // HDR remains a hard failure on an SDR surface, even with valid packets.
      auto hdr = frame;
      hdr[7] |= 0x38;
      assert(renderer.present(hdr.data(), hdr.size(), 64, 64) == PyrowaveDecodeStatus::invalid);
      plane.SetRect(8, 8, 96, 96, 1);
      present(renderer, plane, frame);
      plane.SetVisible(false);
      assert(!plane.PreparePresent());
      plane.SetVisible(true);
      present(renderer, plane, frame);
    }
  }
  gtk_widget_destroy(window);
  pump();
  std::puts("Vulkan: encoded 4:2:0/4:4:4 frames presented; resize, HDR refusal, hide and teardown passed");
}
