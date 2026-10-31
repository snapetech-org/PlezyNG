#if defined(_WIN32)
#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#endif

#include "pme_runtime.h"

#include <onnxruntime_c_api.h>

#include <algorithm>
#include <cctype>
#include <cerrno>
#include <chrono>
#include <condition_variable>
#include <cstdlib>
#include <cstring>
#include <cwctype>
#include <exception>
#include <fstream>
#include <limits>
#include <mutex>
#include <new>
#include <sstream>
#include <string>
#include <utility>
#include <vector>

#if defined(_WIN32)
#include <DirectML.h>
#include <d3d12.h>
#include <dxgi.h>
#include <dxgi1_2.h>
#include <windows.h>
#else
#include <dlfcn.h>
#if defined(__linux__)
#include <dirent.h>
#endif
#endif

#define PME_ORT_API_VERSION 27
#define PME_ORT_LEGACY_MIGRAPHX_API_VERSION 23
#if ORT_API_VERSION < PME_ORT_API_VERSION
#error "Plezy Motion Engine requires ONNX Runtime 1.27 headers"
#endif

#if defined(_WIN32) && defined(PME_HAVE_WINML)
#include <WinMLAsync.h>
#include <WinMLEpCatalog.h>
#endif

struct pme_runtime_session {
#if defined(_WIN32)
  HMODULE runtime_library = nullptr;
  HMODULE directml_runtime_library = nullptr;
  // Keep PME inference on the RX 7900 XT when it is present. If adapter
  // discovery is inconclusive, do not silently continue to a generic GPU
  // provider that may select a different adapter.
  bool rx_7900_xt_target_required = false;
#else
  void* runtime_library = nullptr;
#endif
#if defined(__linux__)
  void* migraphx_runtime_library = nullptr;
  void* hip_runtime_library = nullptr;
#endif
  const OrtApiBase* api_base = nullptr;
  const OrtApi* api = nullptr;
  uint32_t api_version = 0;
  OrtEnv* env = nullptr;
  OrtSession* session = nullptr;
  OrtMemoryInfo* memory_info = nullptr;
  OrtAllocator* allocator = nullptr;
  std::string input_name;
  std::string output_name;
  std::string provider_name;
  std::string provider_vendor;
  std::vector<std::pair<std::string, std::string>> registered_libraries;
  pme_runtime_info info{};
  std::mutex run_mutex;
};

namespace {

using OrtGetApiBaseFn = const OrtApiBase*(ORT_API_CALL*)();

struct OrtValueGuard {
  const OrtApi* api = nullptr;
  OrtValue* value = nullptr;
  ~OrtValueGuard() {
    if (api && value) api->ReleaseValue(value);
  }
};

struct OrtTensorInfoGuard {
  const OrtApi* api = nullptr;
  OrtTensorTypeAndShapeInfo* info = nullptr;
  ~OrtTensorInfoGuard() {
    if (api && info) api->ReleaseTensorTypeAndShapeInfo(info);
  }
};

#if defined(_WIN32)
// The ONNX Runtime DML provider API is returned by GetExecutionProviderApi
// rather than stored in OrtApi. Mirror the DML1 and DML2 prefix while keeping
// DirectML device creation dynamically linked to the Windows ML bundle.
struct PmeOrtDmlDeviceOptions {
  int32_t preference;
  uint32_t filter;
};
using OrtDmlApiMethod = OrtStatus*(ORT_API_CALL*)(void*, void*)NO_EXCEPTION;
using OrtDmlAppendProviderDml1Fn = OrtStatus*(ORT_API_CALL*)(OrtSessionOptions*, IDMLDevice*,
                                                             ID3D12CommandQueue*)NO_EXCEPTION;
using OrtDmlAppendProviderDml2Fn = OrtStatus*(ORT_API_CALL*)(OrtSessionOptions*, PmeOrtDmlDeviceOptions*)NO_EXCEPTION;
struct OrtDmlApiPrefix {
  OrtDmlApiMethod append_dml;
  OrtDmlAppendProviderDml1Fn append_dml1;
  OrtDmlApiMethod create_gpu_allocation;
  OrtDmlApiMethod free_gpu_allocation;
  OrtDmlApiMethod get_d3d12_resource;
  OrtDmlAppendProviderDml2Fn append_dml2;
};
static_assert(sizeof(PmeOrtDmlDeviceOptions) == sizeof(uint32_t) * 2);
static_assert(sizeof(OrtDmlApiMethod) == sizeof(void*));
static_assert(sizeof(OrtDmlApiMethod) == sizeof(OrtDmlAppendProviderDml2Fn));
static_assert(sizeof(OrtDmlApiMethod) == sizeof(OrtDmlAppendProviderDml1Fn));
static_assert(sizeof(OrtDmlApiPrefix) == sizeof(OrtDmlApiMethod) * 6);

struct PmeDirectMLDevice {
  HMODULE runtime_library = nullptr;
  ID3D12Device* d3d_device = nullptr;
  ID3D12CommandQueue* command_queue = nullptr;
  IDMLDevice* device = nullptr;

  ~PmeDirectMLDevice() {
    if (device) device->Release();
    if (command_queue) command_queue->Release();
    if (d3d_device) d3d_device->Release();
    if (runtime_library) FreeLibrary(runtime_library);
  }
};

enum class PmeRx7900XtAdapterProbe { absent, present, unknown };

bool is_rx_7900_xt_adapter(const DXGI_ADAPTER_DESC& description) {
  if (description.VendorId != 0x1002 || description.DeviceId != 0x744c) return false;
  const std::wstring name(description.Description);
  const std::wstring token = L"RX 7900 XT";
  const size_t position = name.find(token);
  if (position == std::wstring::npos) return false;
  const size_t suffix = position + token.size();
  return suffix == name.size() || !std::iswalnum(name[suffix]);
}

PmeRx7900XtAdapterProbe probe_rx_7900_xt_adapter() {
  IDXGIFactory1* factory = nullptr;
  const HRESULT factory_result = CreateDXGIFactory1(IID_PPV_ARGS(&factory));
  if (FAILED(factory_result) || !factory) return PmeRx7900XtAdapterProbe::unknown;

  PmeRx7900XtAdapterProbe probe = PmeRx7900XtAdapterProbe::absent;
  for (UINT index = 0;; ++index) {
    IDXGIAdapter* adapter = nullptr;
    const HRESULT result = factory->EnumAdapters(index, &adapter);
    if (result == DXGI_ERROR_NOT_FOUND) break;
    if (FAILED(result) || !adapter) {
      probe = PmeRx7900XtAdapterProbe::unknown;
      break;
    }

    DXGI_ADAPTER_DESC description{};
    if (FAILED(adapter->GetDesc(&description))) {
      adapter->Release();
      probe = PmeRx7900XtAdapterProbe::unknown;
      break;
    }
    const bool is_target = is_rx_7900_xt_adapter(description);
    adapter->Release();
    if (is_target) {
      probe = PmeRx7900XtAdapterProbe::present;
      break;
    }
  }
  factory->Release();
  return probe;
}

enum class PmeDirectMLTargetStatus { not_found, ready, failed };

PmeDirectMLTargetStatus create_rx_7900_xt_directml_device(PmeDirectMLDevice* target, std::string* error) {
  if (!target || !error) return PmeDirectMLTargetStatus::failed;

  IDXGIFactory1* factory = nullptr;
  HRESULT result = CreateDXGIFactory1(IID_PPV_ARGS(&factory));
  if (FAILED(result) || !factory) {
    *error = "Could not enumerate DXGI adapters for DirectML";
    return PmeDirectMLTargetStatus::failed;
  }

  PmeDirectMLTargetStatus status = PmeDirectMLTargetStatus::not_found;
  for (UINT index = 0;; ++index) {
    IDXGIAdapter* adapter = nullptr;
    result = factory->EnumAdapters(index, &adapter);
    if (result == DXGI_ERROR_NOT_FOUND) break;
    if (FAILED(result) || !adapter) {
      *error = "Could not enumerate DXGI adapters for DirectML";
      status = PmeDirectMLTargetStatus::failed;
      break;
    }

    DXGI_ADAPTER_DESC description{};
    if (SUCCEEDED(adapter->GetDesc(&description)) && is_rx_7900_xt_adapter(description)) {
      result = D3D12CreateDevice(adapter, D3D_FEATURE_LEVEL_11_0, IID_PPV_ARGS(&target->d3d_device));
      adapter->Release();
      if (FAILED(result) || !target->d3d_device) {
        *error = "Could not create a D3D12 device on the RX 7900 XT";
        status = PmeDirectMLTargetStatus::failed;
        break;
      }

      D3D12_COMMAND_QUEUE_DESC queue_description{};
      queue_description.Type = D3D12_COMMAND_LIST_TYPE_COMPUTE;
      result = target->d3d_device->CreateCommandQueue(&queue_description, IID_PPV_ARGS(&target->command_queue));
      if (FAILED(result) || !target->command_queue) {
        *error = "Could not create a DirectML command queue on the RX 7900 XT";
        status = PmeDirectMLTargetStatus::failed;
        break;
      }

      target->runtime_library = LoadLibraryW(L"DirectML.dll");
      if (!target->runtime_library) {
        *error = "Could not load the bundled DirectML runtime";
        status = PmeDirectMLTargetStatus::failed;
        break;
      }
      using DmlCreateDeviceFn = HRESULT(WINAPI*)(ID3D12Device*, DML_CREATE_DEVICE_FLAGS, REFIID, void**);
      const auto create_dml_device =
          reinterpret_cast<DmlCreateDeviceFn>(GetProcAddress(target->runtime_library, "DMLCreateDevice"));
      if (!create_dml_device) {
        *error = "The bundled DirectML runtime does not export DMLCreateDevice";
        status = PmeDirectMLTargetStatus::failed;
        break;
      }
      result = create_dml_device(
          target->d3d_device, DML_CREATE_DEVICE_FLAG_NONE, __uuidof(IDMLDevice),
          reinterpret_cast<void**>(&target->device));
      if (FAILED(result) || !target->device) {
        *error = "Could not create a DirectML device on the RX 7900 XT";
        status = PmeDirectMLTargetStatus::failed;
        break;
      }

      status = PmeDirectMLTargetStatus::ready;
      break;
    }
    adapter->Release();
  }

  factory->Release();
  return status;
}
#endif

void set_error(char* out, size_t capacity, const std::string& message) {
  if (!out || capacity == 0) return;
  const size_t count = std::min(capacity - 1, message.size());
  std::memcpy(out, message.data(), count);
  out[count] = '\0';
}

std::string status_message(const OrtApi* api, OrtStatus* status) {
  if (!status) return {};
  const char* message = api->GetErrorMessage(status);
  std::string result = message ? message : "ONNX Runtime returned an unspecified error";
  api->ReleaseStatus(status);
  return result;
}

#if defined(_WIN32)
std::wstring utf8_to_wide(const char* text) {
  if (!text || !text[0]) return {};
  const int needed = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, -1, nullptr, 0);
  if (needed <= 0) return {};
  std::wstring result(static_cast<size_t>(needed), L'\0');
  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, -1, result.data(), needed) <= 0) return {};
  result.resize(static_cast<size_t>(needed - 1));
  return result;
}

void* load_symbol(HMODULE library, const char* name) { return reinterpret_cast<void*>(GetProcAddress(library, name)); }
#else
void* load_symbol(void* library, const char* name) { return dlsym(library, name); }
#endif

bool valid_string(const char* value) { return value && value[0] != '\0'; }

bool valid_qnn_performance_mode(const char* value) {
  return !valid_string(value) || std::strcmp(value, "burst") == 0 || std::strcmp(value, "balanced") == 0 ||
         std::strcmp(value, "sustained_high_performance") == 0;
}

std::string trim(std::string value) {
  const auto is_space = [](unsigned char ch) { return std::isspace(ch) != 0; };
  value.erase(value.begin(), std::find_if_not(value.begin(), value.end(), is_space));
  value.erase(std::find_if_not(value.rbegin(), value.rend(), is_space).base(), value.end());
  return value;
}

bool parse_device_kind(const std::string& value, pme_device_kind* kind) {
  if (value == "NPU") {
    *kind = PME_DEVICE_NPU;
  } else if (value == "GPU") {
    *kind = PME_DEVICE_GPU;
  } else if (value == "CPU") {
    *kind = PME_DEVICE_CPU;
  } else if (value == "ANY") {
    *kind = PME_DEVICE_ANY;
  } else {
    return false;
  }
  return true;
}

bool is_absolute_path(const std::string& path) {
  if (path.empty()) return false;
  if (path[0] == '/' || path[0] == '\\') return true;
  return path.size() >= 2 && std::isalpha(static_cast<unsigned char>(path[0])) && path[1] == ':';
}

std::string manifest_directory(const std::string& path) {
  const size_t separator = path.find_last_of("/\\");
  return separator == std::string::npos ? std::string() : path.substr(0, separator + 1);
}

struct ManifestProvider {
  std::string name;
  std::string library_path;
  pme_device_kind device_kind = PME_DEVICE_ANY;
};

std::string expected_ep_name(const char* provider_name) {
  if (!provider_name) return {};
  constexpr const char* suffix = "ExecutionProvider";
  const std::string name(provider_name);
  const size_t suffix_length = std::strlen(suffix);
  if (name.size() >= suffix_length && name.compare(name.size() - suffix_length, suffix_length, suffix) == 0) {
    return name;
  }
  return name + suffix;
}

bool is_winml_catalog_provider(const std::string& name) {
  return name == "QNN" || name == "OpenVINO" || name == "VitisAI" || name == "MIGraphX" || name == "NvTensorRtRtx";
}

#if defined(_WIN32) && defined(PME_HAVE_WINML)
bool runtime_cancelled(const pme_runtime_config* config) {
  return config && config->is_cancelled && config->is_cancelled(config->cancel_context) != 0;
}

struct WinMlReadyWait {
  std::mutex mutex;
  std::condition_variable condition;
  bool completed = false;
  HRESULT result = E_FAIL;
};

void CALLBACK winml_ready_completed(WinMLAsyncBlock* async) {
  if (!async || !async->context) return;
  auto* wait = static_cast<WinMlReadyWait*>(async->context);
  const HRESULT result = WinMLAsyncGetStatus(async, FALSE);
  {
    std::lock_guard<std::mutex> lock(wait->mutex);
    wait->result = result;
    wait->completed = true;
  }
  wait->condition.notify_one();
}

bool ensure_winml_provider_ready(WinMLEpHandle provider, const pme_runtime_config* config, std::string* error) {
  if (runtime_cancelled(config)) {
    *error = "Windows ML provider setup was cancelled";
    return false;
  }

  WinMlReadyWait wait;
  WinMLAsyncBlock operation{};
  operation.context = &wait;
  operation.callback = winml_ready_completed;
  HRESULT result = WinMLEpEnsureReadyAsync(provider, &operation);
  if (FAILED(result)) {
    WinMLAsyncClose(&operation);
    *error = "Windows ML could not start provider preparation";
    return false;
  }

  std::unique_lock<std::mutex> lock(wait.mutex);
  while (!wait.completed) {
    wait.condition.wait_for(lock, std::chrono::milliseconds(100));
    if (!wait.completed && runtime_cancelled(config)) {
      lock.unlock();
      WinMLAsyncCancel(&operation);
      lock.lock();
      wait.condition.wait(lock, [&wait] { return wait.completed; });
      break;
    }
  }
  result = wait.result;
  lock.unlock();
  const HRESULT waited_result = WinMLAsyncGetStatus(&operation, TRUE);
  if (FAILED(waited_result)) result = waited_result;
  WinMLAsyncClose(&operation);

  if (runtime_cancelled(config)) {
    *error = "Windows ML provider setup was cancelled";
    return false;
  }
  if (FAILED(result)) {
    *error = "Windows ML could not install or prepare the provider";
    return false;
  }
  return true;
}

bool resolve_winml_provider_library(
    const pme_runtime_config* config, const char* provider_name, std::string* library_path, std::string* error) {
  if (!provider_name || !is_winml_catalog_provider(provider_name) || !library_path) {
    *error = "Windows ML provider manifest entry is not supported";
    return false;
  }

  WinMLEpCatalogHandle catalog = nullptr;
  HRESULT result = WinMLEpCatalogCreate(&catalog);
  if (FAILED(result) || !catalog) {
    *error = "Windows ML execution-provider catalog could not be opened";
    return false;
  }

  WinMLEpHandle provider = nullptr;
  result = WinMLEpCatalogFindProvider(catalog, provider_name, nullptr, &provider);
  if (FAILED(result) || !provider) {
    WinMLEpCatalogRelease(catalog);
    *error = "Windows ML does not list the " + std::string(provider_name) + " provider for this device";
    return false;
  }

  // This runs off mpv's frame callback. Selecting Neural opts in to fetching
  // the matching catalog EP; closing the filter cancels and drains the async
  // catalog operation before its callback state is released.
  if (!ensure_winml_provider_ready(provider, config, error)) {
    WinMLEpCatalogRelease(catalog);
    *error = "Windows ML " + std::string(provider_name) + " provider: " + *error;
    return false;
  }

  size_t path_size = 0;
  result = WinMLEpGetLibraryPathSize(provider, &path_size);
  if (FAILED(result) || path_size == 0) {
    WinMLEpCatalogRelease(catalog);
    *error = "Windows ML returned no library path for " + std::string(provider_name);
    return false;
  }

  std::string path(path_size, '\0');
  size_t path_used = 0;
  result = WinMLEpGetLibraryPath(provider, path_size, path.data(), &path_used);
  WinMLEpCatalogRelease(catalog);
  if (FAILED(result)) {
    *error = "Windows ML could not resolve the " + std::string(provider_name) + " provider library";
    return false;
  }
  if (path_used > path.size()) {
    *error = "Windows ML returned an invalid provider library path length";
    return false;
  }
  if (path_used > 0) path.resize(path_used);
  const size_t terminator = path.find('\0');
  if (terminator != std::string::npos) path.resize(terminator);
  if (path.empty()) {
    *error = "Windows ML returned an empty provider library path";
    return false;
  }
  *library_path = std::move(path);
  return true;
}
#endif

bool read_provider_manifest(const char* path, std::vector<ManifestProvider>* providers, std::string* error) {
  std::ifstream manifest(path);
  if (!manifest) {
    *error = "Could not open motion provider manifest";
    return false;
  }

  const std::string directory = manifest_directory(path);
  std::string line;
  size_t line_number = 0;
  while (std::getline(manifest, line)) {
    ++line_number;
    line = trim(std::move(line));
    if (line.empty() || line[0] == '#') continue;

    const size_t first_separator = line.find('\t');
    const size_t second_separator =
        first_separator == std::string::npos ? std::string::npos : line.find('\t', first_separator + 1);
    if (first_separator == std::string::npos || second_separator == std::string::npos ||
        line.find('\t', second_separator + 1) != std::string::npos) {
      *error =
          "Motion provider manifest line " + std::to_string(line_number) + " must contain three tab-separated fields";
      return false;
    }

    ManifestProvider provider;
    provider.name = trim(line.substr(0, first_separator));
    const std::string kind = trim(line.substr(first_separator + 1, second_separator - first_separator - 1));
    provider.library_path = trim(line.substr(second_separator + 1));
    if (provider.name.empty() || provider.library_path.empty() || !parse_device_kind(kind, &provider.device_kind)) {
      *error = "Motion provider manifest line " + std::to_string(line_number) +
               " has an invalid provider name, device kind, or library path";
      return false;
    }
    if (provider.library_path == "builtin") {
      if (provider.name != "CUDAExecutionProvider" || provider.device_kind != PME_DEVICE_GPU) {
        *error = "The builtin manifest marker currently requires CUDAExecutionProvider with device kind GPU";
        return false;
      }
    } else if (provider.library_path == "builtin-migraphx") {
      if (provider.name != "MIGraphXExecutionProvider" || provider.device_kind != PME_DEVICE_GPU) {
        *error = "The builtin-migraphx marker requires MIGraphXExecutionProvider with device kind GPU";
        return false;
      }
    } else if (provider.library_path == "builtin-dml") {
      if (provider.name != "DmlExecutionProvider" || provider.device_kind != PME_DEVICE_GPU) {
        *error = "The builtin-dml marker requires DmlExecutionProvider with device kind GPU";
        return false;
      }
    } else if (provider.library_path == "builtin-vitisai") {
      if (provider.name != "VitisAIExecutionProvider" || provider.device_kind != PME_DEVICE_NPU) {
        *error = "The builtin-vitisai marker requires VitisAIExecutionProvider with device kind NPU";
        return false;
      }
    } else if (provider.library_path == "windows-ml") {
#if defined(_WIN32) && defined(PME_HAVE_WINML)
      if (!is_winml_catalog_provider(provider.name)) {
        *error = "Windows ML manifest entry names an unsupported execution provider";
        return false;
      }
#else
      *error = "The windows-ml manifest marker requires the Windows ML provider catalog";
      return false;
#endif
    } else if (!is_absolute_path(provider.library_path)) {
      provider.library_path = directory + provider.library_path;
    }
    providers->push_back(std::move(provider));
  }

  if (!manifest.eof() && manifest.fail()) {
    *error = "Could not read motion provider manifest";
    return false;
  }
  if (providers->empty()) {
    *error = "Motion provider manifest does not contain any providers";
    return false;
  }
  return true;
}

bool config_has_builtin_migraphx(const pme_runtime_config* config) {
  if (!config || !config->providers) return false;
  for (size_t i = 0; i < config->provider_count; ++i) {
    const pme_provider_candidate& candidate = config->providers[i];
    if (candidate.struct_size >= sizeof(pme_provider_candidate) && candidate.provider_name &&
        candidate.provider_library_path && candidate.device_kind == PME_DEVICE_GPU &&
        std::strcmp(candidate.provider_name, "MIGraphXExecutionProvider") == 0 &&
        std::strcmp(candidate.provider_library_path, "builtin-migraphx") == 0) {
      return true;
    }
  }
  return false;
}

// ROCm's published monolithic MIGraphX wheel is based on ORT 1.23.2. Its
// built-in provider API is present in C API v23; the compatibility fallback is
// restricted to this provider, while every other provider path requires v27.
bool load_runtime(pme_runtime_session* session, const char* path, bool allow_legacy_migraphx_api, std::string* error) {
#if defined(_WIN32)
  std::wstring runtime_path = utf8_to_wide(path);
  if (valid_string(path) && runtime_path.empty()) {
    *error = "ONNX Runtime path is not valid UTF-8";
    return false;
  }
  session->runtime_library = LoadLibraryW(valid_string(path) ? runtime_path.c_str() : L"onnxruntime.dll");
  if (!session->runtime_library) {
    *error = "Could not load ONNX Runtime (error " + std::to_string(GetLastError()) + ")";
    return false;
  }
#else
  const char* runtime_path = valid_string(path) ? path : "libonnxruntime.so";
#if defined(__APPLE__)
  if (!valid_string(path)) runtime_path = "libonnxruntime.dylib";
#endif
  session->runtime_library = dlopen(runtime_path, RTLD_NOW | RTLD_GLOBAL);
  if (!session->runtime_library) {
    const char* detail = dlerror();
    *error = "Could not load ONNX Runtime";
    if (detail && detail[0]) *error += std::string(": ") + detail;
    return false;
  }
#endif

  auto get_api_base = reinterpret_cast<OrtGetApiBaseFn>(load_symbol(session->runtime_library, "OrtGetApiBase"));
  if (!get_api_base) {
    *error = "ONNX Runtime library does not export OrtGetApiBase";
    return false;
  }
  session->api_base = get_api_base();
  if (!session->api_base) {
    *error = "ONNX Runtime returned no API base";
    return false;
  }
  const char* runtime_version = session->api_base->GetVersionString();
  const bool pinned_ort_123_migraphx =
      allow_legacy_migraphx_api && runtime_version && std::strncmp(runtime_version, "1.23.", 5) == 0;
  if (pinned_ort_123_migraphx) {
    session->api = session->api_base->GetApi(PME_ORT_LEGACY_MIGRAPHX_API_VERSION);
    if (session->api) {
      session->api_version = PME_ORT_LEGACY_MIGRAPHX_API_VERSION;
      return true;
    }
  }
  session->api = session->api_base->GetApi(PME_ORT_API_VERSION);
  if (session->api) {
    session->api_version = PME_ORT_API_VERSION;
    return true;
  }
  if (allow_legacy_migraphx_api) {
    session->api = session->api_base->GetApi(PME_ORT_LEGACY_MIGRAPHX_API_VERSION);
    if (session->api) {
      session->api_version = PME_ORT_LEGACY_MIGRAPHX_API_VERSION;
      return true;
    }
  }
  *error = allow_legacy_migraphx_api ? "ONNX Runtime exposes neither C API v27 nor v23 for built-in MIGraphX"
                                     : "ONNX Runtime library does not provide C API v27 or newer";
  return false;
}

bool call_status(const OrtApi* api, OrtStatus* status, std::string* error, const char* operation) {
  if (!status) return true;
  *error = std::string(operation) + ": " + status_message(api, status);
  return false;
}

bool session_options_create(
    pme_runtime_session* session, const pme_runtime_config* config, OrtSessionOptions** options_out,
    std::string* error) {
  const OrtApi* api = session->api;
  OrtSessionOptions* options = nullptr;
  if (!call_status(api, api->CreateSessionOptions(&options), error, "CreateSessionOptions")) return false;

  const int thread_count = config->intra_op_threads > 0
                               ? static_cast<int>(std::min<uint32_t>(
                                     config->intra_op_threads, static_cast<uint32_t>(std::numeric_limits<int>::max())))
                               : 0;
  if (!call_status(api, api->SetIntraOpNumThreads(options, thread_count), error, "SetIntraOpNumThreads") ||
      !call_status(
          api, api->SetSessionGraphOptimizationLevel(options, ORT_ENABLE_EXTENDED), error,
          "SetSessionGraphOptimizationLevel")) {
    api->ReleaseSessionOptions(options);
    return false;
  }
  *options_out = options;
  return true;
}

bool tensor_schema(
    pme_runtime_session* session, bool input, std::string* name, pme_tensor_shape* shape, std::string* error) {
  const OrtApi* api = session->api;
  size_t count = 0;
  OrtStatus* status = input ? api->SessionGetInputCount(session->session, &count)
                            : api->SessionGetOutputCount(session->session, &count);
  if (!call_status(api, status, error, input ? "SessionGetInputCount" : "SessionGetOutputCount")) return false;
  if (count != 1) {
    *error = input ? "Motion models must have exactly one input tensor"
                   : "Motion models must have exactly one output tensor";
    return false;
  }

  char* allocated_name = nullptr;
  status = input ? api->SessionGetInputName(session->session, 0, session->allocator, &allocated_name)
                 : api->SessionGetOutputName(session->session, 0, session->allocator, &allocated_name);
  if (!call_status(api, status, error, input ? "SessionGetInputName" : "SessionGetOutputName")) return false;
  *name = allocated_name ? allocated_name : "";
  if (allocated_name) session->allocator->Free(session->allocator, allocated_name);
  if (name->empty()) {
    *error = "Motion model tensor name is empty";
    return false;
  }

  OrtTypeInfo* type_info = nullptr;
  status = input ? api->SessionGetInputTypeInfo(session->session, 0, &type_info)
                 : api->SessionGetOutputTypeInfo(session->session, 0, &type_info);
  if (!call_status(api, status, error, input ? "SessionGetInputTypeInfo" : "SessionGetOutputTypeInfo")) return false;

  const OrtTensorTypeAndShapeInfo* tensor_info = nullptr;
  status = api->CastTypeInfoToTensorInfo(type_info, &tensor_info);
  if (!call_status(api, status, error, "CastTypeInfoToTensorInfo")) {
    api->ReleaseTypeInfo(type_info);
    return false;
  }
  if (!tensor_info) {
    api->ReleaseTypeInfo(type_info);
    *error = "Motion model input/output is not a dense tensor";
    return false;
  }

  ONNXTensorElementDataType element_type = ONNX_TENSOR_ELEMENT_DATA_TYPE_UNDEFINED;
  status = api->GetTensorElementType(tensor_info, &element_type);
  if (!call_status(api, status, error, "GetTensorElementType")) {
    api->ReleaseTypeInfo(type_info);
    return false;
  }
  if (element_type != ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT) {
    api->ReleaseTypeInfo(type_info);
    *error = "Motion model input and output tensors must use float32";
    return false;
  }

  size_t rank = 0;
  status = api->GetDimensionsCount(tensor_info, &rank);
  if (!call_status(api, status, error, "GetDimensionsCount")) {
    api->ReleaseTypeInfo(type_info);
    return false;
  }
  if (rank == 0 || rank > PME_RUNTIME_MAX_TENSOR_RANK) {
    api->ReleaseTypeInfo(type_info);
    *error = "Motion model tensor rank is outside the supported range";
    return false;
  }

  shape->rank = static_cast<uint32_t>(rank);
  status = api->GetDimensions(tensor_info, shape->dimensions, rank);
  api->ReleaseTypeInfo(type_info);
  if (!call_status(api, status, error, "GetDimensions")) return false;

  uint64_t elements = 1;
  for (size_t i = 0; i < rank; ++i) {
    const int64_t dimension = shape->dimensions[i];
    if (dimension <= 0 || static_cast<uint64_t>(dimension) > std::numeric_limits<uint64_t>::max() / elements) {
      *error = "Motion model tensor must have fixed, non-zero dimensions";
      return false;
    }
    elements *= static_cast<uint64_t>(dimension);
  }
  shape->element_count = elements;
  return true;
}

bool device_matches(const OrtApi* api, const OrtEpDevice* device, pme_device_kind requested) {
  if (requested == PME_DEVICE_ANY) return true;
  const OrtHardwareDevice* hardware = api->EpDevice_Device(device);
  if (!hardware) return false;
  const OrtHardwareDeviceType type = api->HardwareDevice_Type(hardware);
  if (requested == PME_DEVICE_GPU) return type == OrtHardwareDeviceType_GPU;
  if (requested == PME_DEVICE_NPU) return type == OrtHardwareDeviceType_NPU;
  if (requested == PME_DEVICE_CPU) return type == OrtHardwareDeviceType_CPU;
  return false;
}

struct RequestedWebGpuDevice {
  bool enabled = false;
  bool prefer_rx_7900_xt = false;
  uint32_t vendor_id = 0;
  uint32_t device_id = 0;
};

bool parse_hardware_id(const char* environment_name, uint32_t* output, bool* is_set, std::string* error) {
  const char* value = std::getenv(environment_name);
  if (!value || value[0] == '\0') {
    *is_set = false;
    return true;
  }

  errno = 0;
  char* end = nullptr;
  const bool hex_prefix = value[0] == '0' && (value[1] == 'x' || value[1] == 'X');
  if (hex_prefix) value += 2;
  const unsigned long parsed = std::strtoul(value, &end, hex_prefix ? 16 : 10);
  if (errno != 0 || end == value || *end != '\0' || parsed > std::numeric_limits<uint32_t>::max()) {
    *error = std::string(environment_name) + " must be a decimal or 0x-prefixed 32-bit hardware id";
    return false;
  }
  *output = static_cast<uint32_t>(parsed);
  *is_set = true;
  return true;
}

bool read_requested_webgpu_device(const char* provider_name, RequestedWebGpuDevice* requested, std::string* error) {
  if (!provider_name || std::strcmp(provider_name, "WebGpuExecutionProvider") != 0) return true;

  bool vendor_is_set = false;
  bool device_is_set = false;
  if (!parse_hardware_id("PLEZY_PME_WEBGPU_VENDOR_ID", &requested->vendor_id, &vendor_is_set, error) ||
      !parse_hardware_id("PLEZY_PME_WEBGPU_DEVICE_ID", &requested->device_id, &device_is_set, error)) {
    return false;
  }
  if (vendor_is_set != device_is_set) {
    *error = "Both PLEZY_PME_WEBGPU_VENDOR_ID and PLEZY_PME_WEBGPU_DEVICE_ID are required to pin a WebGPU adapter";
    return false;
  }
  requested->enabled = vendor_is_set;
#if defined(__linux__)
  if (!requested->enabled) {
    // Keep motion inference on the dedicated compute card on the dual-GPU
    // desktop. MPV's presentation renderer selects its device independently.
    requested->prefer_rx_7900_xt = true;
    requested->vendor_id = 0x1002;
    requested->device_id = 0x744c;
  }
#endif
  return true;
}

bool webgpu_device_has_ids(const OrtApi* api, const OrtEpDevice* device, uint32_t vendor_id, uint32_t device_id) {
  const OrtHardwareDevice* hardware = api->EpDevice_Device(device);
  return hardware && api->HardwareDevice_VendorId(hardware) == vendor_id &&
         api->HardwareDevice_DeviceId(hardware) == device_id;
}

bool webgpu_device_matches(const OrtApi* api, const OrtEpDevice* device, const RequestedWebGpuDevice& requested) {
  if (!requested.enabled) return true;
  return webgpu_device_has_ids(api, device, requested.vendor_id, requested.device_id);
}

std::string hardware_provider_label(const OrtApi* api, const OrtHardwareDevice* hardware, const char* fallback) {
  if (!hardware) return fallback ? fallback : "";

  const OrtHardwareDeviceType type = api->HardwareDevice_Type(hardware);
  const uint32_t vendor_id = api->HardwareDevice_VendorId(hardware);
  const uint32_t device_id = api->HardwareDevice_DeviceId(hardware);
  if (type == OrtHardwareDeviceType_GPU && vendor_id == 0x1002) {
    switch (device_id) {
      case 0x744c:
        return "AMD Radeon RX 7900 XT";
      case 0x7550:
        return "AMD Radeon RX 9070 XT";
      default:
        break;
    }
  }

  const char* vendor = api->HardwareDevice_Vendor(hardware);
  std::string vendor_label = vendor && vendor[0] ? vendor : "";
  if (vendor_label.empty()) {
    switch (vendor_id) {
      case 0x1002:
        vendor_label = "AMD";
        break;
      case 0x10de:
        vendor_label = "NVIDIA";
        break;
      case 0x8086:
        vendor_label = "Intel";
        break;
      case 0x5143:
        vendor_label = "Qualcomm";
        break;
      default:
        vendor_label = fallback ? fallback : "";
        break;
    }
  }

  if (type == OrtHardwareDeviceType_GPU && device_id != 0) {
    std::ostringstream label;
    if (!vendor_label.empty()) label << vendor_label << ' ';
    label << "GPU type 0x" << std::hex << device_id;
    return label.str();
  }
  return vendor_label;
}

bool try_accelerator_candidate(
    pme_runtime_session* session, const pme_runtime_config* config, const pme_provider_candidate& candidate,
    std::string* error) {
  const OrtApi* api = session->api;
  if (session->api_version < PME_ORT_API_VERSION) {
    *error = "Plugin execution providers require ONNX Runtime C API version 27 or newer";
    return false;
  }
  if (!valid_string(candidate.provider_name) || !valid_string(candidate.provider_library_path)) {
    *error = "Execution provider candidate is missing its name or library path";
    return false;
  }

  const bool use_windows_ml_catalog = std::strcmp(candidate.provider_library_path, "windows-ml") == 0;
  std::string resolved_library_path;
  if (use_windows_ml_catalog) {
#if defined(_WIN32) && defined(PME_HAVE_WINML)
    const auto existing = std::find_if(
        session->registered_libraries.begin(), session->registered_libraries.end(),
        [&candidate](const auto& entry) { return entry.first == candidate.provider_name; });
    if (existing != session->registered_libraries.end()) {
      resolved_library_path = existing->second;
    } else if (!resolve_winml_provider_library(config, candidate.provider_name, &resolved_library_path, error)) {
      return false;
    }
#else
    *error = "Windows ML provider catalog is unavailable in this runtime";
    return false;
#endif
  } else {
    resolved_library_path = candidate.provider_library_path;
  }
  if (config->is_cancelled && config->is_cancelled(config->cancel_context)) {
    *error = "Motion provider setup was cancelled";
    return false;
  }

  const auto registered = std::find_if(
      session->registered_libraries.begin(), session->registered_libraries.end(),
      [&candidate](const auto& entry) { return entry.first == candidate.provider_name; });
  if (registered != session->registered_libraries.end() && registered->second != resolved_library_path) {
    *error = "Execution provider name was assigned multiple plugin libraries: " + std::string(candidate.provider_name);
    return false;
  }

  if (registered == session->registered_libraries.end()) {
#if defined(_WIN32)
    std::wstring library_path = utf8_to_wide(resolved_library_path.c_str());
    if (library_path.empty()) {
      *error = "Execution provider library path is not valid UTF-8";
      return false;
    }
    OrtStatus* status =
        api->RegisterExecutionProviderLibrary(session->env, candidate.provider_name, library_path.c_str());
#else
    OrtStatus* status =
        api->RegisterExecutionProviderLibrary(session->env, candidate.provider_name, resolved_library_path.c_str());
#endif
    if (!call_status(api, status, error, "RegisterExecutionProviderLibrary")) return false;
    session->registered_libraries.emplace_back(candidate.provider_name, resolved_library_path);
  }

  const OrtEpDevice* const* devices = nullptr;
  size_t device_count = 0;
  if (!call_status(api, api->GetEpDevices(session->env, &devices, &device_count), error, "GetEpDevices")) {
    return false;
  }

  const OrtEpDevice* selected_device = nullptr;
  const OrtEpDevice* first_matching_device = nullptr;
  const std::string expected_provider_name = expected_ep_name(candidate.provider_name);
  RequestedWebGpuDevice requested_webgpu_device;
  if (!read_requested_webgpu_device(candidate.provider_name, &requested_webgpu_device, error)) return false;
  for (size_t i = 0; i < device_count; ++i) {
    const char* ep_name = api->EpDevice_EpName(devices[i]);
    if (!ep_name || expected_provider_name != ep_name || !device_matches(api, devices[i], candidate.device_kind)) {
      continue;
    }
    if (!first_matching_device) first_matching_device = devices[i];
    if (requested_webgpu_device.enabled) {
      if (webgpu_device_matches(api, devices[i], requested_webgpu_device)) {
        selected_device = devices[i];
        break;
      }
    } else if (requested_webgpu_device.prefer_rx_7900_xt) {
      if (webgpu_device_has_ids(
              api, devices[i], requested_webgpu_device.vendor_id, requested_webgpu_device.device_id)) {
        selected_device = devices[i];
        break;
      }
    } else {
      selected_device = devices[i];
      break;
    }
  }
  if (!selected_device && !requested_webgpu_device.enabled) selected_device = first_matching_device;
  if (!selected_device) {
    *error = requested_webgpu_device.enabled
                 ? "WebGPU did not report the requested physical GPU"
                 : "No matching ONNX Runtime device was reported for provider " + std::string(candidate.provider_name);
    return false;
  }

  OrtSessionOptions* options = nullptr;
  if (!session_options_create(session, config, &options, error)) return false;

  // A Neural session may only report this provider after the entire graph is
  // assigned to it. If any operator would fall back to CPU, session creation
  // fails and the caller tries the next provider.
  const bool configure_qnn_power =
      expected_provider_name == "QNNExecutionProvider" && valid_string(config->htp_performance_mode);
  const char* qnn_option_keys[] = {"htp_performance_mode"};
  const char* qnn_option_values[] = {config->htp_performance_mode};
  if (!call_status(
          api, api->AddSessionConfigEntry(options, "session.disable_cpu_ep_fallback", "1"), error,
          "Disable CPU execution provider fallback") ||
      !call_status(
          api,
          api->SessionOptionsAppendExecutionProvider_V2(
              options, session->env, &selected_device, 1, configure_qnn_power ? qnn_option_keys : nullptr,
              configure_qnn_power ? qnn_option_values : nullptr, configure_qnn_power ? 1 : 0),
          error, "SessionOptionsAppendExecutionProvider_V2")) {
    api->ReleaseSessionOptions(options);
    return false;
  }
  if (config->is_cancelled && config->is_cancelled(config->cancel_context)) {
    api->ReleaseSessionOptions(options);
    *error = "Motion provider setup was cancelled";
    return false;
  }

  OrtStatus* status = nullptr;
#if defined(_WIN32)
  std::wstring model_path = utf8_to_wide(config->model_path);
  if (model_path.empty()) {
    api->ReleaseSessionOptions(options);
    *error = "Model path is not valid UTF-8";
    return false;
  }
  status = api->CreateSession(session->env, model_path.c_str(), options, &session->session);
#else
  status = api->CreateSession(session->env, config->model_path, options, &session->session);
#endif
  api->ReleaseSessionOptions(options);
  if (!call_status(api, status, error, "CreateSession with accelerator provider")) return false;

  const OrtEpDevice* output_device = nullptr;
  status = api->SessionGetEpDeviceForOutputs(session->session, &output_device, 1);
  if (!call_status(api, status, error, "SessionGetEpDeviceForOutputs")) {
    api->ReleaseSession(session->session);
    session->session = nullptr;
    return false;
  }
  const char* output_provider = output_device ? api->EpDevice_EpName(output_device) : nullptr;
  if (!output_provider || expected_provider_name != output_provider) {
    api->ReleaseSession(session->session);
    session->session = nullptr;
    *error = "ONNX Runtime did not assign model output to requested provider " + std::string(candidate.provider_name);
    return false;
  }

  if (!device_matches(api, output_device, candidate.device_kind)) {
    api->ReleaseSession(session->session);
    session->session = nullptr;
    *error = "ONNX Runtime assigned model output to a different device kind than requested";
    return false;
  }

  if (!webgpu_device_matches(api, output_device, requested_webgpu_device)) {
    api->ReleaseSession(session->session);
    session->session = nullptr;
    *error = "ONNX Runtime assigned model output to a different WebGPU adapter than requested";
    return false;
  }

  if (requested_webgpu_device.prefer_rx_7900_xt && !requested_webgpu_device.enabled) {
    const OrtHardwareDevice* selected_hardware = api->EpDevice_Device(selected_device);
    const OrtHardwareDevice* output_hardware = api->EpDevice_Device(output_device);
    if (!selected_hardware || !output_hardware ||
        api->HardwareDevice_VendorId(selected_hardware) != api->HardwareDevice_VendorId(output_hardware) ||
        api->HardwareDevice_DeviceId(selected_hardware) != api->HardwareDevice_DeviceId(output_hardware)) {
      api->ReleaseSession(session->session);
      session->session = nullptr;
      *error = "ONNX Runtime assigned model output to a different WebGPU adapter than selected";
      return false;
    }
  }

  const char* provider_vendor = api->EpDevice_EpVendor(output_device);
  const OrtHardwareDevice* hardware = api->EpDevice_Device(output_device);
  session->provider_name = output_provider;
  session->provider_vendor = hardware_provider_label(api, hardware, provider_vendor);
  if (!hardware) {
    session->info.device_kind = candidate.device_kind;
  } else {
    const OrtHardwareDeviceType type = api->HardwareDevice_Type(hardware);
    session->info.device_kind = type == OrtHardwareDeviceType_NPU
                                    ? PME_DEVICE_NPU
                                    : (type == OrtHardwareDeviceType_CPU ? PME_DEVICE_CPU : PME_DEVICE_GPU);
  }
  return true;
}

bool try_builtin_cuda_candidate(
    pme_runtime_session* session, const pme_runtime_config* config, const pme_provider_candidate& candidate,
    std::string* error) {
  if (candidate.device_kind != PME_DEVICE_GPU) {
    *error = "CUDAExecutionProvider must target a GPU device";
    return false;
  }
  const OrtApi* api = session->api;
  OrtSessionOptions* options = nullptr;
  if (!session_options_create(session, config, &options, error)) return false;

  if (!call_status(
          api, api->AddSessionConfigEntry(options, "session.disable_cpu_ep_fallback", "1"), error,
          "Disable CPU execution provider fallback")) {
    api->ReleaseSessionOptions(options);
    return false;
  }

  OrtCUDAProviderOptions cuda_options{};
  cuda_options.device_id = 0;
  if (!call_status(
          api, api->SessionOptionsAppendExecutionProvider_CUDA(options, &cuda_options), error,
          "Append CUDA execution provider")) {
    api->ReleaseSessionOptions(options);
    return false;
  }

#if defined(_WIN32)
  std::wstring model_path = utf8_to_wide(config->model_path);
  if (model_path.empty()) {
    api->ReleaseSessionOptions(options);
    *error = "Model path is not valid UTF-8";
    return false;
  }
  OrtStatus* status = api->CreateSession(session->env, model_path.c_str(), options, &session->session);
#else
  OrtStatus* status = api->CreateSession(session->env, config->model_path, options, &session->session);
#endif
  api->ReleaseSessionOptions(options);
  if (!call_status(api, status, error, "CreateSession with CUDA provider")) return false;

  // CUDA is a built-in EP rather than a plugin EP and does not participate in
  // the OrtEpDevice registration path. With CUDA appended and CPU fallback
  // disabled, successful session creation plus a successful Run is the proof
  // that the graph executed on CUDA.
  session->provider_name = "CUDAExecutionProvider";
  session->provider_vendor = "NVIDIA";
  session->info.device_kind = PME_DEVICE_GPU;
  return true;
}

#if defined(__linux__)
enum class PmeRx7900PciPresence { absent, present, unknown };

struct PmeMigraphxDeviceSelection {
  uint16_t device_id = 0;
  std::string device_name = "AMD";
};

using HipGetDeviceCountFn = int (*)(int*);
using HipDeviceGetNameFn = int (*)(char*, int, int);
using HipDeviceGetPciBusIdFn = int (*)(char*, int, int);

bool parse_sysfs_hex_id(const std::string& text, uint32_t* value) {
  if (!value) return false;
  errno = 0;
  char* end = nullptr;
  const unsigned long parsed = std::strtoul(text.c_str(), &end, 0);
  if (errno != 0 || end == text.c_str() || *end != '\0' || parsed > std::numeric_limits<uint32_t>::max()) {
    return false;
  }
  *value = static_cast<uint32_t>(parsed);
  return true;
}

bool read_linux_pci_identity(const std::string& bus_id, uint32_t* vendor_id, uint32_t* device_id) {
  if (bus_id.empty() || !vendor_id || !device_id) return false;
  const std::string root = "/sys/bus/pci/devices/" + bus_id + "/";
  std::ifstream vendor_file(root + "vendor");
  std::ifstream device_file(root + "device");
  std::string vendor_text;
  std::string device_text;
  if (!vendor_file || !device_file || !std::getline(vendor_file, vendor_text) ||
      !std::getline(device_file, device_text)) {
    return false;
  }
  return parse_sysfs_hex_id(vendor_text, vendor_id) && parse_sysfs_hex_id(device_text, device_id);
}

PmeRx7900PciPresence probe_rx_7900_xt_pci_presence(std::vector<std::string>* navi31_bus_ids) {
  if (!navi31_bus_ids) return PmeRx7900PciPresence::unknown;
  navi31_bus_ids->clear();
  DIR* devices = opendir("/sys/bus/pci/devices");
  if (!devices) return PmeRx7900PciPresence::unknown;

  bool unreadable_identity = false;
  for (dirent* entry = readdir(devices); entry != nullptr; entry = readdir(devices)) {
    if (entry->d_name[0] == '.') continue;
    uint32_t vendor_id = 0;
    uint32_t device_id = 0;
    if (!read_linux_pci_identity(entry->d_name, &vendor_id, &device_id)) {
      unreadable_identity = true;
      continue;
    }
    if (vendor_id == 0x1002 && device_id == 0x744c) {
      navi31_bus_ids->emplace_back(entry->d_name);
    }
  }
  closedir(devices);
  if (!navi31_bus_ids->empty()) return PmeRx7900PciPresence::present;
  return unreadable_identity ? PmeRx7900PciPresence::unknown : PmeRx7900PciPresence::absent;
}

bool is_rx_7900_xt_name(const char* device_name) {
  if (!device_name) return false;
  const std::string name(device_name);
  const std::string token = "RX 7900 XT";
  const size_t position = name.find(token);
  if (position == std::string::npos) return false;
  const size_t suffix = position + token.size();
  return suffix == name.size() || !std::isalnum(static_cast<unsigned char>(name[suffix]));
}

bool explicit_rocm_device_visibility() {
  constexpr const char* variables[] = {"ROCR_VISIBLE_DEVICES", "HIP_VISIBLE_DEVICES", "GPU_DEVICE_ORDINAL"};
  for (const char* variable : variables) {
    const char* value = std::getenv(variable);
    if (value && value[0] != '\0') return true;
  }
  return false;
}

void* load_hip_runtime_for_migraphx(pme_runtime_session* session) {
  if (!session) return nullptr;
  if (session->hip_runtime_library) return session->hip_runtime_library;

  const char* libraries[] = {"libamdhip64.so", "libamdhip64.so.8", "libamdhip64.so.7", "libamdhip64.so.6"};
  int flags = RTLD_NOW | RTLD_LOCAL;
#if defined(RTLD_NODELETE)
  flags |= RTLD_NODELETE;
#endif
  for (const char* library : libraries) {
    session->hip_runtime_library = dlopen(library, flags);
    if (session->hip_runtime_library) return session->hip_runtime_library;
  }
  return nullptr;
}

bool select_migraphx_device(pme_runtime_session* session, PmeMigraphxDeviceSelection* selection, std::string* error) {
  if (!session || !selection || !error) return false;

  void* hip_library = load_hip_runtime_for_migraphx(session);
  const auto get_device_count =
      hip_library ? reinterpret_cast<HipGetDeviceCountFn>(dlsym(hip_library, "hipGetDeviceCount")) : nullptr;
  const auto get_device_name =
      hip_library ? reinterpret_cast<HipDeviceGetNameFn>(dlsym(hip_library, "hipDeviceGetName")) : nullptr;
  const auto get_device_pci_bus_id =
      hip_library ? reinterpret_cast<HipDeviceGetPciBusIdFn>(dlsym(hip_library, "hipDeviceGetPCIBusId")) : nullptr;

  int device_count = 0;
  const bool device_count_known = get_device_count && get_device_count(&device_count) == 0 && device_count >= 0;
  if (explicit_rocm_device_visibility()) {
    // Respect an explicit ROCm/HIP visibility list. MIGraphX device zero is
    // the first device left visible by that user-owned process setting.
    selection->device_id = 0;
    if (device_count_known && device_count > 0 && get_device_name) {
      char name[256] = {};
      if (get_device_name(name, static_cast<int>(sizeof(name)), 0) == 0 && name[0] != '\0') {
        selection->device_name = name;
      }
    }
    return true;
  }

  std::vector<std::string> navi31_bus_ids;
  const PmeRx7900PciPresence pci_presence = probe_rx_7900_xt_pci_presence(&navi31_bus_ids);
  if (!device_count_known || !get_device_name) {
    if (pci_presence != PmeRx7900PciPresence::absent) {
      *error = "Could not query HIP adapters while the RX 7900 XT is present or adapter discovery is incomplete";
      return false;
    }
    selection->device_id = 0;
    return true;
  }

  std::string first_device_name;
  std::vector<std::string> mapped_navi31_bus_ids;
  int selected_device = -1;
  std::string selected_name;
  for (int device = 0; device < device_count; ++device) {
    char name[256] = {};
    if (get_device_name(name, static_cast<int>(sizeof(name)), device) != 0 || name[0] == '\0') {
      if (pci_presence != PmeRx7900PciPresence::absent) {
        *error = "HIP could not identify every visible adapter while selecting RX 7900 XT compute";
        return false;
      }
      continue;
    }
    if (device == 0) first_device_name = name;

    char bus_id[64] = {};
    uint32_t vendor_id = 0;
    uint32_t pci_device_id = 0;
    const bool pci_identity_known = get_device_pci_bus_id &&
                                    get_device_pci_bus_id(bus_id, static_cast<int>(sizeof(bus_id)), device) == 0 &&
                                    bus_id[0] != '\0' && read_linux_pci_identity(bus_id, &vendor_id, &pci_device_id);
    const bool is_navi31_pci_device = pci_identity_known && vendor_id == 0x1002 && pci_device_id == 0x744c;
    if (is_navi31_pci_device &&
        std::find(navi31_bus_ids.begin(), navi31_bus_ids.end(), std::string(bus_id)) != navi31_bus_ids.end() &&
        std::find(mapped_navi31_bus_ids.begin(), mapped_navi31_bus_ids.end(), std::string(bus_id)) ==
            mapped_navi31_bus_ids.end()) {
      mapped_navi31_bus_ids.emplace_back(bus_id);
    }

    if (!is_rx_7900_xt_name(name)) continue;
    if (pci_identity_known && (vendor_id != 0x1002 || pci_device_id != 0x744c)) {
      continue;
    }
    if (selected_device >= 0) {
      *error = "More than one RX 7900 XT is visible to HIP; set ROCR_VISIBLE_DEVICES to select one explicitly";
      return false;
    }
    selected_device = device;
    selected_name = name;
  }

  if (selected_device >= 0) {
    if (selected_device > std::numeric_limits<uint16_t>::max()) {
      *error = "HIP RX 7900 XT device ordinal exceeds MIGraphX's supported device-id range";
      return false;
    }
    selection->device_id = static_cast<uint16_t>(selected_device);
    selection->device_name = selected_name;
    return true;
  }

  if (pci_presence == PmeRx7900PciPresence::unknown ||
      (pci_presence == PmeRx7900PciPresence::present && mapped_navi31_bus_ids.size() != navi31_bus_ids.size())) {
    *error = "RX 7900 XT adapter discovery is incomplete; refusing MIGraphX device 0";
    return false;
  }

  selection->device_id = 0;
  if (!first_device_name.empty()) selection->device_name = first_device_name;
  return true;
}
#endif

bool try_builtin_migraphx_candidate(
    pme_runtime_session* session, const pme_runtime_config* config, const pme_provider_candidate& candidate,
    std::string* error) {
#if !defined(_WIN32)
  if (candidate.device_kind != PME_DEVICE_GPU) {
    *error = "MIGraphXExecutionProvider must target a GPU device";
    return false;
  }
#if defined(__linux__)
  // The AMD provider depends on libmigraphx_c.so.3 but does not include an
  // RPATH. Preload the bundled runtime (when present) so its RUNPATH can find
  // sibling libraries, and keep MIGraphX's global loader state mapped after
  // the ONNX Runtime session is released. Unloading it during MPV teardown
  // previously faulted in libmigraphx's dynamic_loader_impl destructor.
  if (!session->migraphx_runtime_library) {
    std::vector<std::string> candidates;
    if (valid_string(config->runtime_library_path)) {
      const std::string runtime_path(config->runtime_library_path);
      const size_t separator = runtime_path.find_last_of('/');
      if (separator != std::string::npos) {
        candidates.push_back(runtime_path.substr(0, separator + 1) + "libmigraphx_c.so.3");
      }
    }
    candidates.emplace_back("libmigraphx_c.so.3");

    std::string last_error;
    for (const std::string& path : candidates) {
      dlerror();
      int flags = RTLD_NOW | RTLD_GLOBAL;
#if defined(RTLD_NODELETE)
      flags |= RTLD_NODELETE;
#endif
      session->migraphx_runtime_library = dlopen(path.c_str(), flags);
      if (session->migraphx_runtime_library) break;
      const char* detail = dlerror();
      if (detail && detail[0]) last_error = detail;
    }
    if (!session->migraphx_runtime_library) {
      *error = "Could not load AMD MIGraphX runtime libmigraphx_c.so.3";
      if (!last_error.empty()) *error += ": " + last_error;
      return false;
    }
  }
#endif
  const OrtApi* api = session->api;
  if (session->api_version < PME_ORT_LEGACY_MIGRAPHX_API_VERSION ||
      !api->SessionOptionsAppendExecutionProvider_MIGraphX) {
    *error = "ONNX Runtime does not expose its built-in MIGraphX provider API";
    return false;
  }
#if defined(__linux__)
  PmeMigraphxDeviceSelection device_selection;
  if (!select_migraphx_device(session, &device_selection, error)) return false;
  const uint16_t migraphx_device_id = device_selection.device_id;
  const std::string migraphx_device_name = device_selection.device_name;
#else
  const uint16_t migraphx_device_id = 0;
  const std::string migraphx_device_name = "AMD";
#endif
  OrtSessionOptions* options = nullptr;
  if (!session_options_create(session, config, &options, error)) return false;

  OrtMIGraphXProviderOptions migraphx_options{};
  migraphx_options.device_id = migraphx_device_id;
  if (!call_status(
          api, api->AddSessionConfigEntry(options, "session.disable_cpu_ep_fallback", "1"), error,
          "Disable CPU execution provider fallback") ||
      !call_status(
          api, api->SessionOptionsAppendExecutionProvider_MIGraphX(options, &migraphx_options), error,
          "Append MIGraphX execution provider")) {
    api->ReleaseSessionOptions(options);
    return false;
  }

  if (config->is_cancelled && config->is_cancelled(config->cancel_context)) {
    api->ReleaseSessionOptions(options);
    *error = "Motion provider setup was cancelled";
    return false;
  }

  OrtStatus* status = api->CreateSession(session->env, config->model_path, options, &session->session);
  api->ReleaseSessionOptions(options);
  if (!call_status(api, status, error, "CreateSession with MIGraphX provider")) return false;

  // CPU EP fallback is disabled. A successful run therefore confirms that
  // the model graph was assigned to the AMD GPU provider.
  session->provider_name = "MIGraphXExecutionProvider";
  session->provider_vendor = migraphx_device_name;
  session->info.device_kind = PME_DEVICE_GPU;
  return true;
#else
  (void)session;
  (void)config;
  (void)candidate;
  *error = "MIGraphX execution is available only on Linux";
  return false;
#endif
}

bool try_builtin_dml_candidate(
    pme_runtime_session* session, const pme_runtime_config* config, const pme_provider_candidate& candidate,
    std::string* error) {
#if defined(_WIN32)
  if (candidate.device_kind != PME_DEVICE_GPU) {
    *error = "DmlExecutionProvider must target a GPU device";
    return false;
  }

  const OrtApi* api = session->api;
  const void* provider_api = nullptr;
  if (!call_status(
          api, api->GetExecutionProviderApi("DML", PME_ORT_API_VERSION, &provider_api), error,
          "Get DirectML provider API")) {
    return false;
  }
  if (!provider_api) {
    *error = "ONNX Runtime returned no DirectML provider API";
    return false;
  }
  OrtDmlApiPrefix dml_api{};
  std::memcpy(&dml_api, provider_api, sizeof(dml_api));

  PmeDirectMLDevice dml_target;
  std::string target_error;
  const PmeDirectMLTargetStatus target_status = create_rx_7900_xt_directml_device(&dml_target, &target_error);
  if (target_status == PmeDirectMLTargetStatus::failed) {
    *error = target_error;
    return false;
  }
  if (session->rx_7900_xt_target_required && target_status != PmeDirectMLTargetStatus::ready) {
    *error = "Could not confirm the RX 7900 XT DirectML adapter";
    return false;
  }
  const bool pin_rx_7900_xt = target_status == PmeDirectMLTargetStatus::ready;

  OrtSessionOptions* options = nullptr;
  if (!session_options_create(session, config, &options, error)) return false;
  PmeOrtDmlDeviceOptions device_options{1, 1};  // HighPerformance, GPU
  if (!call_status(api, api->DisableMemPattern(options), error, "Disable DirectML memory pattern") ||
      !call_status(
          api, api->SetSessionExecutionMode(options, ORT_SEQUENTIAL), error, "Set DirectML sequential execution") ||
      !call_status(
          api, api->AddSessionConfigEntry(options, "session.disable_cpu_ep_fallback", "1"), error,
          "Disable CPU execution provider fallback")) {
    api->ReleaseSessionOptions(options);
    return false;
  }

  OrtStatus* append_status = nullptr;
  if (pin_rx_7900_xt) {
    // DML2 cannot target a specific adapter, so pass the explicit 7900 XT
    // device and queue through the current DML1 API.
    if (!dml_api.append_dml1) {
      api->ReleaseSessionOptions(options);
      *error = "ONNX Runtime DirectML API cannot bind the RX 7900 XT device";
      return false;
    }
    append_status = dml_api.append_dml1(options, dml_target.device, dml_target.command_queue);
    session->directml_runtime_library = dml_target.runtime_library;
    dml_target.runtime_library = nullptr;
  } else {
    if (!dml_api.append_dml2) {
      api->ReleaseSessionOptions(options);
      *error = "ONNX Runtime DirectML API has no DML2 session append function";
      return false;
    }
    append_status = dml_api.append_dml2(options, &device_options);
  }
  if (!call_status(
          api, append_status, error,
          pin_rx_7900_xt ? "Append DirectML device on RX 7900 XT" : "Append DirectML high-performance GPU")) {
    api->ReleaseSessionOptions(options);
    return false;
  }

  std::wstring model_path = utf8_to_wide(config->model_path);
  if (model_path.empty()) {
    api->ReleaseSessionOptions(options);
    *error = "Model path is not valid UTF-8";
    return false;
  }
  OrtStatus* status = api->CreateSession(session->env, model_path.c_str(), options, &session->session);
  api->ReleaseSessionOptions(options);
  if (!call_status(api, status, error, "CreateSession with DirectML provider")) return false;

  // DML is a built-in EP and does not use OrtEpDevice registration. CPU EP
  // fallback is disabled, so session initialization cannot silently split
  // unsupported nodes onto CPU. Run calls are serialized by pme_runtime_run.
  session->provider_name = candidate.provider_name;
  session->provider_vendor = pin_rx_7900_xt ? "AMD Radeon RX 7900 XT" : "Microsoft DirectML GPU";
  session->info.device_kind = PME_DEVICE_GPU;
  return true;
#else
  (void)session;
  (void)config;
  (void)candidate;
  *error = "DirectML execution is available only on Windows";
  return false;
#endif
}

bool try_builtin_vitisai_candidate(
    pme_runtime_session* session, const pme_runtime_config* config, const pme_provider_candidate& candidate,
    std::string* error) {
  if (candidate.device_kind != PME_DEVICE_NPU) {
    *error = "VitisAIExecutionProvider must target an NPU device";
    return false;
  }

  const OrtApi* api = session->api;
  OrtSessionOptions* options = nullptr;
  if (!session_options_create(session, config, &options, error)) return false;
  if (!call_status(
          api, api->AddSessionConfigEntry(options, "session.disable_cpu_ep_fallback", "1"), error,
          "Disable CPU execution provider fallback") ||
      !call_status(
          api, api->SessionOptionsAppendExecutionProvider_VitisAI(options, nullptr, nullptr, 0), error,
          "Append Vitis AI execution provider")) {
    api->ReleaseSessionOptions(options);
    return false;
  }

#if defined(_WIN32)
  std::wstring model_path = utf8_to_wide(config->model_path);
  if (model_path.empty()) {
    api->ReleaseSessionOptions(options);
    *error = "Model path is not valid UTF-8";
    return false;
  }
  OrtStatus* status = api->CreateSession(session->env, model_path.c_str(), options, &session->session);
#else
  OrtStatus* status = api->CreateSession(session->env, config->model_path, options, &session->session);
#endif
  api->ReleaseSessionOptions(options);
  if (!call_status(api, status, error, "CreateSession with Vitis AI provider")) return false;

  // Vitis AI is exposed through the built-in C API. CPU EP fallback is
  // disabled, so unsupported model nodes cannot quietly run on the CPU.
  session->provider_name = candidate.provider_name;
  session->provider_vendor = "AMD";
  session->info.device_kind = PME_DEVICE_NPU;
  return true;
}

bool try_cpu_provider(pme_runtime_session* session, const pme_runtime_config* config, std::string* error) {
  const OrtApi* api = session->api;
  OrtSessionOptions* options = nullptr;
  if (!session_options_create(session, config, &options, error)) return false;

#if defined(_WIN32)
  std::wstring model_path = utf8_to_wide(config->model_path);
  if (model_path.empty()) {
    api->ReleaseSessionOptions(options);
    *error = "Model path is not valid UTF-8";
    return false;
  }
  OrtStatus* status = api->CreateSession(session->env, model_path.c_str(), options, &session->session);
#else
  OrtStatus* status = api->CreateSession(session->env, config->model_path, options, &session->session);
#endif
  api->ReleaseSessionOptions(options);
  if (!call_status(api, status, error, "CreateSession with CPU provider")) return false;
  session->provider_name = "CPUExecutionProvider";
  session->provider_vendor.clear();
  session->info.device_kind = PME_DEVICE_CPU;
  return true;
}

void release_session(pme_runtime_session* session) {
  if (!session) return;
  const OrtApi* api = session->api;
  if (api) {
    if (session->session) {
      api->ReleaseSession(session->session);
      session->session = nullptr;
    }
    if (session->memory_info) {
      api->ReleaseMemoryInfo(session->memory_info);
      session->memory_info = nullptr;
    }
    if (session->env) {
      for (auto it = session->registered_libraries.rbegin(); it != session->registered_libraries.rend(); ++it) {
        OrtStatus* status = api->UnregisterExecutionProviderLibrary(session->env, it->first.c_str());
        if (status) api->ReleaseStatus(status);
      }
      session->registered_libraries.clear();
      api->ReleaseEnv(session->env);
      session->env = nullptr;
    }
  }
#if defined(_WIN32)
  if (session->directml_runtime_library) {
    FreeLibrary(session->directml_runtime_library);
    session->directml_runtime_library = nullptr;
  }
  if (session->runtime_library) {
    FreeLibrary(session->runtime_library);
    session->runtime_library = nullptr;
  }
#else
  if (session->runtime_library) {
    dlclose(session->runtime_library);
    session->runtime_library = nullptr;
  }
#if defined(__linux__)
  if (session->hip_runtime_library) {
#if defined(RTLD_NODELETE)
    dlclose(session->hip_runtime_library);
#else
    // Keep HIP mapped until process exit when the platform cannot mark the
    // runtime NODELETE; MIGraphX may retain HIP-owned global state at teardown.
#endif
    session->hip_runtime_library = nullptr;
  }
  if (session->migraphx_runtime_library) {
#if defined(RTLD_NODELETE)
    dlclose(session->migraphx_runtime_library);
#else
    // On Linux libcs without RTLD_NODELETE, retain this loader reference until
    // process exit so MIGraphX's global state cannot be unloaded at teardown.
#endif
    session->migraphx_runtime_library = nullptr;
  }
#endif
#endif
}

}  // namespace

extern "C" PME_RUNTIME_API int pme_runtime_open(
    const pme_runtime_config* config, pme_runtime_session** session_out, char* error_out, size_t error_capacity) {
  if (session_out) *session_out = nullptr;
  if (!config || !session_out || config->struct_size < sizeof(pme_runtime_config) ||
      config->abi_version != PME_RUNTIME_ABI_VERSION || !valid_string(config->model_path) ||
      (config->provider_count != 0 && !config->providers)) {
    set_error(error_out, error_capacity, "Invalid Plezy Motion Engine runtime configuration");
    return -1;
  }
  if (!valid_qnn_performance_mode(config->htp_performance_mode)) {
    set_error(error_out, error_capacity, "Unsupported QNN HTP performance mode");
    return -1;
  }

  auto* session = new (std::nothrow) pme_runtime_session();
  if (!session) {
    set_error(error_out, error_capacity, "Could not allocate motion model session");
    return -1;
  }

  try {
    std::string error;
    if (!load_runtime(session, config->runtime_library_path, config_has_builtin_migraphx(config), &error) ||
        !call_status(
            session->api, session->api->CreateEnv(ORT_LOGGING_LEVEL_ERROR, "PlezyMotionEngine", &session->env), &error,
            "CreateEnv") ||
        !call_status(
            session->api, session->api->GetAllocatorWithDefaultOptions(&session->allocator), &error,
            "GetAllocatorWithDefaultOptions") ||
        !call_status(
            session->api,
            session->api->CreateMemoryInfo("Cpu", OrtArenaAllocator, 0, OrtMemTypeDefault, &session->memory_info),
            &error, "CreateMemoryInfo")) {
      release_session(session);
      delete session;
      set_error(error_out, error_capacity, error);
      return -1;
    }

    bool opened = false;
    std::string last_provider_error;
#if defined(_WIN32)
    session->rx_7900_xt_target_required = probe_rx_7900_xt_adapter() != PmeRx7900XtAdapterProbe::absent;
#endif
    std::vector<size_t> provider_order;
    provider_order.reserve(config->provider_count);
    for (size_t i = 0; i < config->provider_count; ++i) provider_order.push_back(i);
#if defined(_WIN32)
    if (session->rx_7900_xt_target_required) {
      const auto is_builtin_dml_at = [&](size_t index) {
        const pme_provider_candidate& candidate = config->providers[index];
        return candidate.struct_size >= sizeof(pme_provider_candidate) && candidate.provider_name &&
               candidate.provider_library_path && std::strcmp(candidate.provider_name, "DmlExecutionProvider") == 0 &&
               std::strcmp(candidate.provider_library_path, "builtin-dml") == 0;
      };
      const auto is_gpu_at = [&](size_t index) {
        const pme_provider_candidate& candidate = config->providers[index];
        return candidate.struct_size >= sizeof(pme_provider_candidate) && candidate.device_kind == PME_DEVICE_GPU;
      };
      const auto dml = std::find_if(provider_order.begin(), provider_order.end(), is_builtin_dml_at);
      const auto first_gpu = std::find_if(provider_order.begin(), provider_order.end(), is_gpu_at);
      if (dml != provider_order.end() && first_gpu != provider_order.end() && dml > first_gpu) {
        const size_t dml_index = *dml;
        provider_order.erase(dml);
        const auto insertion = std::find_if(provider_order.begin(), provider_order.end(), is_gpu_at);
        provider_order.insert(insertion, dml_index);
      }
    }
#endif
    for (size_t order_index = 0; order_index < provider_order.size() && !opened; ++order_index) {
      const size_t i = provider_order[order_index];
      if (config->is_cancelled && config->is_cancelled(config->cancel_context)) {
        last_provider_error = "Motion provider setup was cancelled";
        break;
      }
      if (config->providers[i].struct_size < sizeof(pme_provider_candidate)) {
        last_provider_error = "Execution provider candidate has an incompatible structure size";
        continue;
      }
      std::string candidate_error;
      const pme_provider_candidate& candidate = config->providers[i];
      const bool builtin_cuda = candidate.provider_name && candidate.provider_library_path &&
                                std::strcmp(candidate.provider_name, "CUDAExecutionProvider") == 0 &&
                                std::strcmp(candidate.provider_library_path, "builtin") == 0;
      const bool builtin_migraphx = candidate.provider_name && candidate.provider_library_path &&
                                    std::strcmp(candidate.provider_name, "MIGraphXExecutionProvider") == 0 &&
                                    std::strcmp(candidate.provider_library_path, "builtin-migraphx") == 0;
      const bool builtin_dml = candidate.provider_name && candidate.provider_library_path &&
                               std::strcmp(candidate.provider_name, "DmlExecutionProvider") == 0 &&
                               std::strcmp(candidate.provider_library_path, "builtin-dml") == 0;
#if defined(_WIN32)
      if (session->rx_7900_xt_target_required && candidate.device_kind == PME_DEVICE_GPU && !builtin_dml) {
        if (last_provider_error.empty()) {
          last_provider_error = std::string(candidate.provider_name ? candidate.provider_name : "GPU provider") +
                                ": skipped to keep PME compute on the RX 7900 XT";
        }
        continue;
      }
#endif
      const bool builtin_vitisai = candidate.provider_name && candidate.provider_library_path &&
                                   std::strcmp(candidate.provider_name, "VitisAIExecutionProvider") == 0 &&
                                   std::strcmp(candidate.provider_library_path, "builtin-vitisai") == 0;
      if (session->api_version < PME_ORT_API_VERSION && !builtin_migraphx) {
        last_provider_error = std::string(candidate.provider_name ? candidate.provider_name : "unnamed provider") +
                              ": ONNX Runtime C API v23 compatibility is restricted to built-in MIGraphX";
        continue;
      }
      const bool opened_candidate =
          builtin_cuda
              ? try_builtin_cuda_candidate(session, config, candidate, &candidate_error)
              : (builtin_migraphx
                     ? try_builtin_migraphx_candidate(session, config, candidate, &candidate_error)
                     : (builtin_dml ? try_builtin_dml_candidate(session, config, candidate, &candidate_error)
                                    : (builtin_vitisai
                                           ? try_builtin_vitisai_candidate(session, config, candidate, &candidate_error)
                                           : try_accelerator_candidate(session, config, candidate, &candidate_error))));
      if (opened_candidate) {
        opened = true;
      } else {
        last_provider_error =
            std::string(config->providers[i].provider_name ? config->providers[i].provider_name : "unnamed provider") +
            ": " + candidate_error;
      }
    }

    const bool cancelled = config->is_cancelled && config->is_cancelled(config->cancel_context);
    if (!opened && config->allow_cpu_provider && !cancelled) {
      error.clear();
      opened = try_cpu_provider(session, config, &error);
      if (!opened && !last_provider_error.empty()) error = last_provider_error + "; CPU: " + error;
    } else if (!opened) {
      error = cancelled ? "Motion provider setup was cancelled"
                        : (last_provider_error.empty() ? "No accelerator provider candidate was supplied"
                                                       : last_provider_error);
    }

    if (opened && config->is_cancelled && config->is_cancelled(config->cancel_context)) {
      release_session(session);
      delete session;
      set_error(error_out, error_capacity, "Motion provider setup was cancelled");
      return -1;
    }

    if (opened) {
      if (!tensor_schema(session, true, &session->input_name, &session->info.input, &error) ||
          !tensor_schema(session, false, &session->output_name, &session->info.output, &error)) {
        opened = false;
      }
    }

    if (opened) {
      session->info.struct_size = sizeof(pme_runtime_info);
      session->info.abi_version = PME_RUNTIME_ABI_VERSION;
      std::strncpy(
          session->info.provider_name, session->provider_name.c_str(), sizeof(session->info.provider_name) - 1);
      std::strncpy(
          session->info.provider_vendor, session->provider_vendor.c_str(), sizeof(session->info.provider_vendor) - 1);
      *session_out = session;
      set_error(error_out, error_capacity, "");
      return 0;
    }

    release_session(session);
    delete session;
    set_error(error_out, error_capacity, error);
    return -1;
  } catch (const std::exception& exception) {
    release_session(session);
    delete session;
    set_error(error_out, error_capacity, std::string("Motion runtime initialization failed: ") + exception.what());
    return -1;
  } catch (...) {
    release_session(session);
    delete session;
    set_error(error_out, error_capacity, "Motion runtime initialization failed with an unknown error");
    return -1;
  }
}

extern "C" PME_RUNTIME_API int pme_runtime_open_from_manifest(
    const pme_runtime_config* config, const char* provider_manifest_path, pme_runtime_session** session_out,
    char* error_out, size_t error_capacity) {
  if (session_out) *session_out = nullptr;
  if (!config || !session_out || config->struct_size < sizeof(pme_runtime_config) ||
      config->abi_version != PME_RUNTIME_ABI_VERSION || !valid_string(provider_manifest_path)) {
    set_error(error_out, error_capacity, "Invalid Plezy Motion Engine manifest configuration");
    return -1;
  }

  try {
    std::vector<ManifestProvider> manifest_providers;
    std::string error;
    if (!read_provider_manifest(provider_manifest_path, &manifest_providers, &error)) {
      set_error(error_out, error_capacity, error);
      return -1;
    }

    std::vector<pme_provider_candidate> candidates;
    candidates.reserve(manifest_providers.size());
    for (const auto& provider : manifest_providers) {
      pme_provider_candidate candidate{};
      candidate.struct_size = sizeof(candidate);
      candidate.provider_name = provider.name.c_str();
      candidate.provider_library_path = provider.library_path.c_str();
      candidate.device_kind = provider.device_kind;
      candidates.push_back(candidate);
    }

    pme_runtime_config manifest_config = *config;
    manifest_config.providers = candidates.data();
    manifest_config.provider_count = candidates.size();
    return pme_runtime_open(&manifest_config, session_out, error_out, error_capacity);
  } catch (const std::exception& exception) {
    set_error(error_out, error_capacity, std::string("Motion provider manifest failed: ") + exception.what());
    return -1;
  } catch (...) {
    set_error(error_out, error_capacity, "Motion provider manifest failed with an unknown error");
    return -1;
  }
}

extern "C" PME_RUNTIME_API int pme_runtime_get_info(const pme_runtime_session* session, pme_runtime_info* info_out) {
  if (!session || !info_out || info_out->struct_size < sizeof(pme_runtime_info)) return -1;
  *info_out = session->info;
  return 0;
}

extern "C" PME_RUNTIME_API int pme_runtime_run(
    pme_runtime_session* session, const float* input, uint64_t input_element_count, float* output,
    uint64_t output_capacity, uint64_t* output_element_count, char* error_out, size_t error_capacity) {
  if (output_element_count) *output_element_count = 0;
  if (!session || !input || !output || !output_element_count ||
      input_element_count != session->info.input.element_count ||
      output_capacity < session->info.output.element_count ||
      session->info.input.element_count > std::numeric_limits<size_t>::max() / sizeof(float) ||
      session->info.output.element_count > std::numeric_limits<size_t>::max() / sizeof(float)) {
    set_error(error_out, error_capacity, "Invalid motion inference tensor buffer or shape");
    return -1;
  }

  try {
    const OrtApi* api = session->api;
    std::lock_guard<std::mutex> lock(session->run_mutex);
    OrtValue* input_value_raw = nullptr;
    OrtStatus* status = api->CreateTensorWithDataAsOrtValue(
        session->memory_info, const_cast<float*>(input), static_cast<size_t>(input_element_count) * sizeof(float),
        session->info.input.dimensions, session->info.input.rank, ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT,
        &input_value_raw);
    std::string error;
    if (status) {
      error = std::string("CreateTensorWithDataAsOrtValue: ") + status_message(api, status);
      if (input_value_raw) api->ReleaseValue(input_value_raw);
      set_error(error_out, error_capacity, error);
      return -1;
    }
    OrtValueGuard input_value{api, input_value_raw};

    const char* input_names[] = {session->input_name.c_str()};
    const char* output_names[] = {session->output_name.c_str()};
    const OrtValue* input_values[] = {input_value.value};
    OrtValue* output_value_raw = nullptr;
    status = api->Run(session->session, nullptr, input_names, input_values, 1, output_names, 1, &output_value_raw);
    OrtValueGuard output_value{api, output_value_raw};
    if (status) {
      error = std::string("ONNX Runtime inference failed: ") + status_message(api, status);
      set_error(error_out, error_capacity, error);
      return -1;
    }
    if (!output_value.value) {
      set_error(error_out, error_capacity, "ONNX Runtime returned no output tensor");
      return -1;
    }

    OrtTensorTypeAndShapeInfo* output_info_raw = nullptr;
    status = api->GetTensorTypeAndShape(output_value.value, &output_info_raw);
    OrtTensorInfoGuard output_info{api, output_info_raw};
    if (status) {
      error = std::string("GetTensorTypeAndShape: ") + status_message(api, status);
      set_error(error_out, error_capacity, error);
      return -1;
    }
    size_t output_elements = 0;
    status = api->GetTensorShapeElementCount(output_info.info, &output_elements);
    if (status) {
      error = std::string("GetTensorShapeElementCount: ") + status_message(api, status);
      set_error(error_out, error_capacity, error);
      return -1;
    }
    ONNXTensorElementDataType output_type = ONNX_TENSOR_ELEMENT_DATA_TYPE_UNDEFINED;
    status = api->GetTensorElementType(output_info.info, &output_type);
    if (status) {
      error = std::string("GetTensorElementType: ") + status_message(api, status);
      set_error(error_out, error_capacity, error);
      return -1;
    }
    if (output_type != ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT || output_elements != session->info.output.element_count ||
        output_elements > output_capacity) {
      set_error(error_out, error_capacity, "ONNX Runtime output shape/type differs from the opened model schema");
      return -1;
    }

    void* output_data = nullptr;
    status = api->GetTensorMutableData(output_value.value, &output_data);
    if (status || !output_data) {
      error = status ? std::string("GetTensorMutableData: ") + status_message(api, status)
                     : "ONNX Runtime output tensor has no data";
      set_error(error_out, error_capacity, error);
      return -1;
    }

    std::memcpy(output, output_data, output_elements * sizeof(float));
    *output_element_count = static_cast<uint64_t>(output_elements);
    set_error(error_out, error_capacity, "");
    return 0;
  } catch (const std::exception& exception) {
    set_error(error_out, error_capacity, std::string("Motion inference failed: ") + exception.what());
    return -1;
  } catch (...) {
    set_error(error_out, error_capacity, "Motion inference failed with an unknown error");
    return -1;
  }
}

extern "C" PME_RUNTIME_API void pme_runtime_close(pme_runtime_session* session) {
  if (!session) return;
  release_session(session);
  delete session;
}
