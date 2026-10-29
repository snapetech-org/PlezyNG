// SPDX-License-Identifier: GPL-3.0-or-later
#include "steam_microphone_capture.h"
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <audioclient.h>
#include <mmdeviceapi.h>
#include <windows.h>
#include <wrl/client.h>

#include <algorithm>
#include <array>
#include <cstring>
#include <thread>

using Microsoft::WRL::ComPtr;
namespace plezy::steam {
namespace {
void capture(const std::shared_ptr<Runtime>& runtime, MicrophoneLease lease) {
  ComPtr<IMMDeviceEnumerator> devices;
  ComPtr<IMMDevice> device;
  ComPtr<IAudioClient> client;
  ComPtr<IAudioCaptureClient> input;
  if (!runtime->microphoneCurrent(lease.epoch) ||
      FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, IID_PPV_ARGS(&devices))) ||
      FAILED(devices->GetDefaultAudioEndpoint(eCapture, eCommunications, &device)) ||
      FAILED(device->Activate(
          __uuidof(IAudioClient), CLSCTX_ALL, nullptr, reinterpret_cast<void**>(client.GetAddressOf()))))
    return;
  WAVEFORMATEX format{};
  format.wFormatTag = WAVE_FORMAT_PCM;
  format.nChannels = static_cast<WORD>(lease.channels);
  format.nSamplesPerSec = lease.rate;
  format.wBitsPerSample = 16;
  format.nBlockAlign = static_cast<WORD>(lease.channels * 2);
  format.nAvgBytesPerSec = format.nSamplesPerSec * format.nBlockAlign;
  if (FAILED(client->Initialize(
          AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY,
          1000000, 0, &format, nullptr)) ||
      FAILED(client->GetService(IID_PPV_ARGS(&input))) || !runtime->microphoneCurrent(lease.epoch) ||
      FAILED(client->Start()))
    return;
  std::array<int16_t, 11520> pcm{};
  bool healthy = true;
  auto last = std::chrono::steady_clock::now();
  while (healthy && runtime->microphoneCurrent(lease.epoch)) {
    UINT32 available = 0;
    if (FAILED(input->GetNextPacketSize(&available))) break;
    if (!available) {
      if (std::chrono::steady_clock::now() - last > std::chrono::seconds(3)) break;
      std::this_thread::sleep_for(std::chrono::milliseconds(5));
      continue;
    }
    BYTE* bytes = nullptr;
    UINT32 frames = 0;
    DWORD flags = 0;
    if (FAILED(input->GetBuffer(&bytes, &frames, &flags, nullptr, nullptr))) break;
    last = std::chrono::steady_clock::now();
    // Reject oversized device batches instead of allocating or accumulating
    // microphone audio. WASAPI discontinuities cannot replay old samples.
    const size_t count = size_t(frames) * lease.channels;
    healthy = count && count <= pcm.size();
    if (healthy) {
      if (flags & AUDCLNT_BUFFERFLAGS_SILENT)
        pcm.fill(0);
      else if (bytes)
        std::memcpy(pcm.data(), bytes, count * sizeof(int16_t));
      else
        healthy = false;
    }
    if (healthy) healthy = runtime->microphonePcm(lease.epoch, pcm.data(), count);
    pcm.fill(0);
    if (FAILED(input->ReleaseBuffer(frames))) healthy = false;
  }
  client->Stop();
  pcm.fill(0);
}
}  // namespace
bool startMicrophoneCapture(std::shared_ptr<Runtime> runtime) {
  if (!runtime) return false;
  const auto lease = runtime->beginMicrophone();
  if (!lease) return false;
  try {
    std::thread([runtime, lease] {
      const HRESULT com = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
      if (SUCCEEDED(com)) {
        capture(runtime, lease);
        CoUninitialize();
      }
      runtime->finishMicrophone(lease.epoch);
    }).detach();
  } catch (...) {
    runtime->finishMicrophone(lease.epoch);
    return false;
  }
  return true;
}
}  // namespace plezy::steam
