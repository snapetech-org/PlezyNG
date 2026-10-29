// SPDX-License-Identifier: GPL-3.0-or-later
#include "steam_vulkan_presenter.h"

#include <algorithm>
#include <array>
#include <cstring>
#include <stdexcept>
#include <utility>

#if PLEZY_STEAM_PYROWAVE
#define VK_NO_PROTOTYPES
#include <vulkan/vulkan.h>
#if defined(_WIN32)
#include <vulkan/vulkan_win32.h>
#include <windows.h>
#elif defined(__ANDROID__)
#include <android/native_window.h>
#include <vulkan/vulkan_android.h>
#else
struct wl_display;
struct wl_surface;
#include <vulkan/vulkan_wayland.h>
#endif
#ifndef _WIN32
#include <dlfcn.h>
#endif
#include <pyrowave.h>

#include "shaders/steam_video_spirv.h"

namespace plezy::steam {
namespace {
constexpr uint64_t kGpuTimeout = 250000000;  // 250ms; never block the receiver on a hung frame.
#define INSTANCE_FUNCTIONS(X)                                                                                         \
  X(DestroyInstance)                                                                                                  \
  X(EnumeratePhysicalDevices)                                                                                         \
  X(GetPhysicalDeviceProperties) X(GetPhysicalDeviceFeatures2) X(GetPhysicalDeviceQueueFamilyProperties)              \
      X(GetPhysicalDeviceMemoryProperties) X(GetPhysicalDeviceFormatProperties) X(GetPhysicalDeviceSurfaceSupportKHR) \
          X(GetPhysicalDeviceSurfaceCapabilitiesKHR) X(GetPhysicalDeviceSurfaceFormatsKHR)                            \
              X(EnumerateDeviceExtensionProperties) X(CreateDevice) X(GetDeviceProcAddr) X(DestroySurfaceKHR)
#define DEVICE_FUNCTIONS(X)                                                                                           \
  X(DestroyDevice)                                                                                                    \
  X(GetDeviceQueue)                                                                                                   \
  X(DeviceWaitIdle) X(CreateSwapchainKHR) X(DestroySwapchainKHR) X(GetSwapchainImagesKHR) X(AcquireNextImageKHR)      \
      X(QueuePresentKHR) X(QueueSubmit) X(CreateCommandPool) X(DestroyCommandPool) X(AllocateCommandBuffers)          \
          X(ResetCommandPool) X(BeginCommandBuffer) X(EndCommandBuffer) X(CreateFence) X(DestroyFence)                \
              X(WaitForFences) X(ResetFences) X(CreateSemaphore) X(DestroySemaphore) X(CreateImage) X(DestroyImage)   \
                  X(GetImageMemoryRequirements) X(AllocateMemory) X(FreeMemory) X(BindImageMemory) X(CreateImageView) \
                      X(DestroyImageView) X(CreateSampler) X(DestroySampler) X(CreateDescriptorSetLayout)             \
                          X(DestroyDescriptorSetLayout) X(CreateDescriptorPool) X(DestroyDescriptorPool)              \
                              X(AllocateDescriptorSets) X(UpdateDescriptorSets) X(CreatePipelineLayout)               \
                                  X(DestroyPipelineLayout) X(CreateShaderModule) X(DestroyShaderModule)               \
                                      X(CreateRenderPass) X(DestroyRenderPass) X(CreateGraphicsPipelines)             \
                                          X(DestroyPipeline) X(CreateFramebuffer) X(DestroyFramebuffer)               \
                                              X(CmdPipelineBarrier) X(CmdBeginRenderPass) X(CmdEndRenderPass)         \
                                                  X(CmdBindPipeline) X(CmdBindDescriptorSets) X(CmdPushConstants)     \
                                                      X(CmdSetViewport) X(CmdSetScissor) X(CmdDraw)
struct Dispatch {
  PFN_vkGetInstanceProcAddr GetInstanceProcAddr = nullptr;
#define DECLARE(name) PFN_vk##name name = nullptr;
  INSTANCE_FUNCTIONS(DECLARE)
  DEVICE_FUNCTIONS(DECLARE)
#undef DECLARE
};
void check(VkResult result) {
  if (result != VK_SUCCESS) throw std::runtime_error("Vulkan presentation unavailable");
}
template <typename T>
T structure(VkStructureType type) {
  T result{};
  result.sType = type;
  return result;
}
bool isHdr(VkSurfaceFormatKHR format) {
  return format.colorSpace == VK_COLOR_SPACE_HDR10_ST2084_EXT &&
         (format.format == VK_FORMAT_A2B10G10R10_UNORM_PACK32 || format.format == VK_FORMAT_A2R10G10B10_UNORM_PACK32);
}
bool isSdr(VkSurfaceFormatKHR format) {
  return format.colorSpace == VK_COLOR_SPACE_SRGB_NONLINEAR_KHR &&
         (format.format == VK_FORMAT_B8G8R8A8_UNORM || format.format == VK_FORMAT_R8G8B8A8_UNORM);
}
}  // namespace

struct VulkanPresenter::Impl {
  Dispatch vk;
  void* loader = nullptr;
  VkInstance instance = VK_NULL_HANDLE;
  VkPhysicalDevice physical = VK_NULL_HANDLE;
  VkDevice device = VK_NULL_HANDLE;
  VkSurfaceKHR surface = VK_NULL_HANDLE;
  VkQueue queue = VK_NULL_HANDLE;
  uint32_t family = 0;
  pyrowave_device pyro = nullptr;
  pyrowave_decoder decoder = nullptr;
  bool hdrSupported = false, hdrActive = false, allowHdr = false, failed = false;
  bool chroma444 = false;
  int width = 0, height = 0;
  std::vector<uint8_t> initial;
  VkPhysicalDeviceMemoryProperties memory{};
  // Pyrowave borrows every pointer in these structures for its whole lifetime.
  VkApplicationInfo application = structure<VkApplicationInfo>(VK_STRUCTURE_TYPE_APPLICATION_INFO);
  VkInstanceCreateInfo instanceInfo = structure<VkInstanceCreateInfo>(VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO);
  std::vector<const char*> instanceExtensions;
  VkPhysicalDeviceFeatures2 features =
      structure<VkPhysicalDeviceFeatures2>(VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2);
  VkPhysicalDeviceVulkan11Features features11 =
      structure<VkPhysicalDeviceVulkan11Features>(VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES);
  VkPhysicalDeviceVulkan12Features features12 =
      structure<VkPhysicalDeviceVulkan12Features>(VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES);
  VkPhysicalDeviceVulkan13Features features13 =
      structure<VkPhysicalDeviceVulkan13Features>(VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES);
  float priority = 1.0f;
  const char* deviceExtension = VK_KHR_SWAPCHAIN_EXTENSION_NAME;
  VkDeviceQueueCreateInfo queueInfo = structure<VkDeviceQueueCreateInfo>(VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO);
  VkDeviceCreateInfo deviceInfo = structure<VkDeviceCreateInfo>(VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO);
  pyrowave_device_create_queue_info pyroQueue{};
  VkCommandPool commandPool = VK_NULL_HANDLE;
  VkCommandBuffer command = VK_NULL_HANDLE;
  VkFence fence = VK_NULL_HANDLE;
  VkSemaphore acquired = VK_NULL_HANDLE, decoded = VK_NULL_HANDLE;
  VkSampler sampler = VK_NULL_HANDLE;
  VkDescriptorSetLayout descriptorLayout = VK_NULL_HANDLE;
  VkDescriptorPool descriptorPool = VK_NULL_HANDLE;
  VkDescriptorSet descriptors = VK_NULL_HANDLE;
  VkPipelineLayout pipelineLayout = VK_NULL_HANDLE;
  VkSwapchainKHR swapchain = VK_NULL_HANDLE;
  VkExtent2D extent{};
  VkFormat format = VK_FORMAT_UNDEFINED;
  VkRenderPass renderPass = VK_NULL_HANDLE;
  VkPipeline pipeline = VK_NULL_HANDLE;
  std::vector<VkImage> images;
  std::vector<VkImageView> views;
  std::vector<VkFramebuffer> framebuffers;
  // One signal semaphore per image; reacquiring that image proves the WSI wait
  // consumed its previous signal. A submit fence alone does not prove that.
  std::vector<VkSemaphore> finished;
  struct Plane {
    VkImage image = VK_NULL_HANDLE;
    VkImageView view = VK_NULL_HANDLE;
    VkDeviceMemory memory = VK_NULL_HANDLE;
    uint32_t width = 0, height = 0;
  } planes[3];

  ~Impl() { close(); }
  void destroyPlanes() {
    if (decoder) pyrowave_decoder_destroy(decoder);
    decoder = nullptr;
    for (auto& plane : planes) {
      if (plane.view) vk.DestroyImageView(device, plane.view, nullptr);
      if (plane.image) vk.DestroyImage(device, plane.image, nullptr);
      if (plane.memory) vk.FreeMemory(device, plane.memory, nullptr);
      plane = {};
    }
  }
  void destroySwapchain() {
    for (auto object : framebuffers) vk.DestroyFramebuffer(device, object, nullptr);
    for (auto object : views) vk.DestroyImageView(device, object, nullptr);
    for (auto object : finished) vk.DestroySemaphore(device, object, nullptr);
    framebuffers.clear();
    views.clear();
    finished.clear();
    images.clear();
    if (pipeline) vk.DestroyPipeline(device, pipeline, nullptr);
    if (renderPass) vk.DestroyRenderPass(device, renderPass, nullptr);
    if (swapchain) vk.DestroySwapchainKHR(device, swapchain, nullptr);
    pipeline = VK_NULL_HANDLE;
    renderPass = VK_NULL_HANDLE;
    swapchain = VK_NULL_HANDLE;
    extent = {};
    format = VK_FORMAT_UNDEFINED;
  }
  void close() {
    // The driver owns submitted objects until idle, including after a timeout.
    // Never free those objects in an attempted "bounded" use-after-free cleanup.
    if (device && vk.DeviceWaitIdle) vk.DeviceWaitIdle(device);
    destroyPlanes();
    if (pyro) pyrowave_device_destroy(pyro);
    pyro = nullptr;
    destroySwapchain();
    if (pipelineLayout) vk.DestroyPipelineLayout(device, pipelineLayout, nullptr);
    if (descriptorPool) vk.DestroyDescriptorPool(device, descriptorPool, nullptr);
    if (descriptorLayout) vk.DestroyDescriptorSetLayout(device, descriptorLayout, nullptr);
    if (sampler) vk.DestroySampler(device, sampler, nullptr);
    if (decoded) vk.DestroySemaphore(device, decoded, nullptr);
    if (acquired) vk.DestroySemaphore(device, acquired, nullptr);
    if (fence) vk.DestroyFence(device, fence, nullptr);
    if (commandPool) vk.DestroyCommandPool(device, commandPool, nullptr);
    if (device && vk.DestroyDevice) vk.DestroyDevice(device, nullptr);
    if (surface && vk.DestroySurfaceKHR) vk.DestroySurfaceKHR(instance, surface, nullptr);
    if (instance && vk.DestroyInstance) vk.DestroyInstance(instance, nullptr);
    if (loader) {
#ifdef _WIN32
      FreeLibrary(static_cast<HMODULE>(loader));
#else
      dlclose(loader);
#endif
    }
  }
  std::vector<VkSurfaceFormatKHR> formats() {
    uint32_t count = 0;
    check(vk.GetPhysicalDeviceSurfaceFormatsKHR(physical, surface, &count, nullptr));
    if (!count || count > 256) throw std::runtime_error("No bounded surface formats");
    std::vector<VkSurfaceFormatKHR> result(count);
    check(vk.GetPhysicalDeviceSurfaceFormatsKHR(physical, surface, &count, result.data()));
    result.resize(count);
    return result;
  }
  bool open(GpuWindow window, bool hdr) {
    allowHdr = hdr;
#if defined(_WIN32)
    if (window.kind != GpuWindow::Kind::win32 || !window.window) return false;
    loader = LoadLibraryExW(L"vulkan-1.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
    const char* platformExtension = VK_KHR_WIN32_SURFACE_EXTENSION_NAME;
#elif defined(__ANDROID__)
    if (window.kind != GpuWindow::Kind::android || !window.window) return false;
    loader = dlopen("libvulkan.so", RTLD_NOW | RTLD_LOCAL);
    const char* platformExtension = VK_KHR_ANDROID_SURFACE_EXTENSION_NAME;
#else
    if (window.kind != GpuWindow::Kind::wayland || !window.window || !window.display) return false;
    loader = dlopen("libvulkan.so.1", RTLD_NOW | RTLD_LOCAL);
    const char* platformExtension = VK_KHR_WAYLAND_SURFACE_EXTENSION_NAME;
#endif
    if (!loader) return false;
#ifdef _WIN32
    const auto entry = GetProcAddress(static_cast<HMODULE>(loader), "vkGetInstanceProcAddr");
    static_assert(sizeof(entry) == sizeof(vk.GetInstanceProcAddr));
    std::memcpy(&vk.GetInstanceProcAddr, &entry, sizeof(entry));
#else
    vk.GetInstanceProcAddr = reinterpret_cast<PFN_vkGetInstanceProcAddr>(dlsym(loader, "vkGetInstanceProcAddr"));
#endif
    if (!vk.GetInstanceProcAddr) return false;
    auto enumerate = reinterpret_cast<PFN_vkEnumerateInstanceExtensionProperties>(
        vk.GetInstanceProcAddr(nullptr, "vkEnumerateInstanceExtensionProperties"));
    auto create = reinterpret_cast<PFN_vkCreateInstance>(vk.GetInstanceProcAddr(nullptr, "vkCreateInstance"));
    if (!enumerate || !create) return false;
    uint32_t count = 0;
    check(enumerate(nullptr, &count, nullptr));
    if (count > 4096) return false;
    std::vector<VkExtensionProperties> extensions(count);
    check(enumerate(nullptr, &count, extensions.data()));
    instanceExtensions = {VK_KHR_SURFACE_EXTENSION_NAME, platformExtension};
    if (std::any_of(extensions.begin(), extensions.end(), [](const auto& e) {
          return std::strcmp(e.extensionName, VK_EXT_SWAPCHAIN_COLOR_SPACE_EXTENSION_NAME) == 0;
        }))
      instanceExtensions.push_back(VK_EXT_SWAPCHAIN_COLOR_SPACE_EXTENSION_NAME);
    application.apiVersion = VK_API_VERSION_1_3;
    application.pApplicationName = "PlezyNG Steam";
    instanceInfo.pApplicationInfo = &application;
    instanceInfo.enabledExtensionCount = static_cast<uint32_t>(instanceExtensions.size());
    instanceInfo.ppEnabledExtensionNames = instanceExtensions.data();
    check(create(&instanceInfo, nullptr, &instance));
#define LOAD_INSTANCE(name)                                                               \
  vk.name = reinterpret_cast<PFN_vk##name>(vk.GetInstanceProcAddr(instance, "vk" #name)); \
  if (!vk.name) return false;
    INSTANCE_FUNCTIONS(LOAD_INSTANCE)
#undef LOAD_INSTANCE
#if defined(_WIN32)
    auto createSurface =
        reinterpret_cast<PFN_vkCreateWin32SurfaceKHR>(vk.GetInstanceProcAddr(instance, "vkCreateWin32SurfaceKHR"));
    auto surfaceInfo = structure<VkWin32SurfaceCreateInfoKHR>(VK_STRUCTURE_TYPE_WIN32_SURFACE_CREATE_INFO_KHR);
    surfaceInfo.hinstance = GetModuleHandleW(nullptr);
    surfaceInfo.hwnd = static_cast<HWND>(window.window);
#elif defined(__ANDROID__)
    auto createSurface =
        reinterpret_cast<PFN_vkCreateAndroidSurfaceKHR>(vk.GetInstanceProcAddr(instance, "vkCreateAndroidSurfaceKHR"));
    auto surfaceInfo = structure<VkAndroidSurfaceCreateInfoKHR>(VK_STRUCTURE_TYPE_ANDROID_SURFACE_CREATE_INFO_KHR);
    surfaceInfo.window = static_cast<ANativeWindow*>(window.window);
#else
    auto createSurface =
        reinterpret_cast<PFN_vkCreateWaylandSurfaceKHR>(vk.GetInstanceProcAddr(instance, "vkCreateWaylandSurfaceKHR"));
    auto surfaceInfo = structure<VkWaylandSurfaceCreateInfoKHR>(VK_STRUCTURE_TYPE_WAYLAND_SURFACE_CREATE_INFO_KHR);
    surfaceInfo.display = static_cast<wl_display*>(window.display);
    surfaceInfo.surface = static_cast<wl_surface*>(window.window);
#endif
    if (!createSurface) return false;
    check(createSurface(instance, &surfaceInfo, nullptr, &surface));
    check(vk.EnumeratePhysicalDevices(instance, &count, nullptr));
    if (!count || count > 32) return false;
    std::vector<VkPhysicalDevice> devices(count);
    check(vk.EnumeratePhysicalDevices(instance, &count, devices.data()));
    for (auto candidate : devices) {
      VkPhysicalDeviceProperties properties{};
      vk.GetPhysicalDeviceProperties(candidate, &properties);
      // Direct presentation must not silently select a CPU Vulkan driver.
      // Software implementations are neither a latency/power qualification nor
      // a safe fallback for this codec's subgroup-heavy decode shaders.
      if (properties.apiVersion < VK_API_VERSION_1_3 || properties.deviceType == VK_PHYSICAL_DEVICE_TYPE_CPU) continue;
      VkFormatProperties planeFormat{};
      vk.GetPhysicalDeviceFormatProperties(candidate, VK_FORMAT_R16_UNORM, &planeFormat);
      const VkFormatFeatureFlags required = VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT | VK_FORMAT_FEATURE_STORAGE_IMAGE_BIT |
                                            VK_FORMAT_FEATURE_SAMPLED_IMAGE_FILTER_LINEAR_BIT;
      if ((planeFormat.optimalTilingFeatures & required) != required) continue;
      uint32_t queueCount = 0;
      vk.GetPhysicalDeviceQueueFamilyProperties(candidate, &queueCount, nullptr);
      if (queueCount > 256) continue;
      std::vector<VkQueueFamilyProperties> queues(queueCount);
      vk.GetPhysicalDeviceQueueFamilyProperties(candidate, &queueCount, queues.data());
      for (uint32_t i = 0; i < queueCount; ++i) {
        VkBool32 present = VK_FALSE;
        check(vk.GetPhysicalDeviceSurfaceSupportKHR(candidate, i, surface, &present));
        if (!present || (queues[i].queueFlags & (VK_QUEUE_GRAPHICS_BIT | VK_QUEUE_COMPUTE_BIT)) !=
                            (VK_QUEUE_GRAPHICS_BIT | VK_QUEUE_COMPUTE_BIT))
          continue;
        physical = candidate;
        family = i;
        break;
      }
      if (physical) break;
    }
    if (!physical) return false;
    features.pNext = &features11;
    features11.pNext = &features12;
    features12.pNext = &features13;
    vk.GetPhysicalDeviceFeatures2(physical, &features);
    if (!features13.subgroupSizeControl || !features13.synchronization2 || !features12.timelineSemaphore ||
        !features.features.shaderStorageImageExtendedFormats)
      return false;
    // The private device has no protected resources and no capture/replay use.
    features11.protectedMemory = VK_FALSE;
    features12.bufferDeviceAddressCaptureReplay = VK_FALSE;
    queueInfo.queueFamilyIndex = family;
    queueInfo.queueCount = 1;
    queueInfo.pQueuePriorities = &priority;
    deviceInfo.pNext = &features;
    deviceInfo.queueCreateInfoCount = 1;
    deviceInfo.pQueueCreateInfos = &queueInfo;
    deviceInfo.enabledExtensionCount = 1;
    deviceInfo.ppEnabledExtensionNames = &deviceExtension;
    check(vk.CreateDevice(physical, &deviceInfo, nullptr, &device));
#define LOAD_DEVICE(name)                                                             \
  vk.name = reinterpret_cast<PFN_vk##name>(vk.GetDeviceProcAddr(device, "vk" #name)); \
  if (!vk.name) return false;
    DEVICE_FUNCTIONS(LOAD_DEVICE)
#undef LOAD_DEVICE
    vk.GetDeviceQueue(device, family, 0, &queue);
    vk.GetPhysicalDeviceMemoryProperties(physical, &memory);
    pyroQueue = {queue, family, 0};
    pyrowave_device_create_info borrowed{};
    borrowed.GetInstanceProcAddr = vk.GetInstanceProcAddr;
    borrowed.instance = instance;
    borrowed.physical_device = physical;
    borrowed.device = device;
    borrowed.instance_create_info = &instanceInfo;
    borrowed.device_create_info = &deviceInfo;
    borrowed.queue_info = &pyroQueue;
    borrowed.queue_info_count = 1;
    if (pyrowave_create_device(&borrowed, &pyro) != PYROWAVE_SUCCESS || !pyro) return false;
    auto availableFormats = formats();
    hdrSupported = allowHdr && std::any_of(availableFormats.begin(), availableFormats.end(), isHdr);
    if (!std::any_of(availableFormats.begin(), availableFormats.end(), isSdr)) return false;
    auto poolInfo = structure<VkCommandPoolCreateInfo>(VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO);
    poolInfo.queueFamilyIndex = family;
    check(vk.CreateCommandPool(device, &poolInfo, nullptr, &commandPool));
    auto allocate = structure<VkCommandBufferAllocateInfo>(VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO);
    allocate.commandPool = commandPool;
    allocate.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    allocate.commandBufferCount = 1;
    check(vk.AllocateCommandBuffers(device, &allocate, &command));
    auto fenceInfo = structure<VkFenceCreateInfo>(VK_STRUCTURE_TYPE_FENCE_CREATE_INFO);
    fenceInfo.flags = VK_FENCE_CREATE_SIGNALED_BIT;
    check(vk.CreateFence(device, &fenceInfo, nullptr, &fence));
    auto semaphore = structure<VkSemaphoreCreateInfo>(VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO);
    check(vk.CreateSemaphore(device, &semaphore, nullptr, &acquired));
    check(vk.CreateSemaphore(device, &semaphore, nullptr, &decoded));
    auto samplerInfo = structure<VkSamplerCreateInfo>(VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO);
    samplerInfo.magFilter = samplerInfo.minFilter = VK_FILTER_LINEAR;
    samplerInfo.addressModeU = samplerInfo.addressModeV = samplerInfo.addressModeW =
        VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    check(vk.CreateSampler(device, &samplerInfo, nullptr, &sampler));
    VkDescriptorSetLayoutBinding bindings[3]{};
    for (uint32_t i = 0; i < 3; ++i)
      bindings[i] = {i, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 1, VK_SHADER_STAGE_FRAGMENT_BIT, nullptr};
    auto layout = structure<VkDescriptorSetLayoutCreateInfo>(VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO);
    layout.bindingCount = 3;
    layout.pBindings = bindings;
    check(vk.CreateDescriptorSetLayout(device, &layout, nullptr, &descriptorLayout));
    VkDescriptorPoolSize poolSize{VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 3};
    auto descriptorInfo = structure<VkDescriptorPoolCreateInfo>(VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO);
    descriptorInfo.maxSets = 1;
    descriptorInfo.poolSizeCount = 1;
    descriptorInfo.pPoolSizes = &poolSize;
    check(vk.CreateDescriptorPool(device, &descriptorInfo, nullptr, &descriptorPool));
    auto setInfo = structure<VkDescriptorSetAllocateInfo>(VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO);
    setInfo.descriptorPool = descriptorPool;
    setInfo.descriptorSetCount = 1;
    setInfo.pSetLayouts = &descriptorLayout;
    check(vk.AllocateDescriptorSets(device, &setInfo, &descriptors));
    VkPushConstantRange push{VK_SHADER_STAGE_FRAGMENT_BIT, 0, 8 * sizeof(float)};
    auto pipelineInfo = structure<VkPipelineLayoutCreateInfo>(VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO);
    pipelineInfo.setLayoutCount = 1;
    pipelineInfo.pSetLayouts = &descriptorLayout;
    pipelineInfo.pushConstantRangeCount = 1;
    pipelineInfo.pPushConstantRanges = &push;
    check(vk.CreatePipelineLayout(device, &pipelineInfo, nullptr, &pipelineLayout));
    return true;
  }
  void createPlanes(bool fullChroma) {
    destroyPlanes();
    chroma444 = fullChroma;
    pyrowave_decoder_create_info info{};
    info.device = pyro;
    info.width = width;
    info.height = height;
    info.chroma = fullChroma ? PYROWAVE_CHROMA_SUBSAMPLING_444 : PYROWAVE_CHROMA_SUBSAMPLING_420;
    // Compute allows UNORM16 on devices without R16 color-attachment support.
    info.fragment_path = false;
    if (pyrowave_decoder_create(&info, &decoder) != PYROWAVE_SUCCESS)
      throw std::runtime_error("GPU decoder unavailable");
    for (uint32_t i = 0; i < 3; ++i) {
      auto& plane = planes[i];
      plane.width = i && !fullChroma ? width / 2 : width;
      plane.height = i && !fullChroma ? height / 2 : height;
      auto image = structure<VkImageCreateInfo>(VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO);
      image.imageType = VK_IMAGE_TYPE_2D;
      image.format = VK_FORMAT_R16_UNORM;
      image.extent = {plane.width, plane.height, 1};
      image.mipLevels = image.arrayLayers = 1;
      image.samples = VK_SAMPLE_COUNT_1_BIT;
      image.tiling = VK_IMAGE_TILING_OPTIMAL;
      image.usage = VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_STORAGE_BIT;
      check(vk.CreateImage(device, &image, nullptr, &plane.image));
      VkMemoryRequirements required{};
      vk.GetImageMemoryRequirements(device, plane.image, &required);
      uint32_t type = 0;
      while (type < memory.memoryTypeCount &&
             (!(required.memoryTypeBits & (1u << type)) ||
              !(memory.memoryTypes[type].propertyFlags & VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)))
        ++type;
      if (type == memory.memoryTypeCount) throw std::runtime_error("No GPU plane memory");
      auto allocation = structure<VkMemoryAllocateInfo>(VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO);
      allocation.allocationSize = required.size;
      allocation.memoryTypeIndex = type;
      check(vk.AllocateMemory(device, &allocation, nullptr, &plane.memory));
      check(vk.BindImageMemory(device, plane.image, plane.memory, 0));
      auto view = structure<VkImageViewCreateInfo>(VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO);
      view.image = plane.image;
      view.viewType = VK_IMAGE_VIEW_TYPE_2D;
      view.format = image.format;
      view.subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
      check(vk.CreateImageView(device, &view, nullptr, &plane.view));
      VkDescriptorImageInfo descriptor{sampler, plane.view, VK_IMAGE_LAYOUT_GENERAL};
      auto write = structure<VkWriteDescriptorSet>(VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET);
      write.dstSet = descriptors;
      write.dstBinding = i;
      write.descriptorCount = 1;
      write.descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
      write.pImageInfo = &descriptor;
      vk.UpdateDescriptorSets(device, 1, &write, 0, nullptr);
    }
    if (!initial.empty()) {
      PyrowaveFrameInfo first;
      if (!parsePyrowaveFrame(initial.data(), initial.size(), width, height, first, true, hdrSupported) ||
          first.chroma444 != chroma444 ||
          pyrowave_decoder_push_packet(decoder, initial.data(), initial.size()) != PYROWAVE_SUCCESS)
        throw std::runtime_error("Invalid initial GPU frame");
      initial.clear();
    }
  }
  void createSwapchain(int outputWidth, int outputHeight, bool hdr) {
    check(vk.DeviceWaitIdle(device));
    destroySwapchain();
    VkSurfaceCapabilitiesKHR caps{};
    check(vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(physical, surface, &caps));
    auto availableFormats = formats();
    auto selected = std::find_if(availableFormats.begin(), availableFormats.end(), hdr ? isHdr : isSdr);
    if (selected == availableFormats.end() || !(caps.supportedUsageFlags & VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT))
      throw std::runtime_error("Output color space unavailable");
    extent = caps.currentExtent;
    if (extent.width == UINT32_MAX) {
      extent.width = std::clamp(uint32_t(outputWidth), caps.minImageExtent.width, caps.maxImageExtent.width);
      extent.height = std::clamp(uint32_t(outputHeight), caps.minImageExtent.height, caps.maxImageExtent.height);
    }
    if (!extent.width || !extent.height || extent.width > 16384 || extent.height > 16384)
      throw std::runtime_error("Invalid native window extent");
    auto info = structure<VkSwapchainCreateInfoKHR>(VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR);
    info.surface = surface;
    info.minImageCount = caps.minImageCount + 1;
    if (caps.maxImageCount) info.minImageCount = std::min(info.minImageCount, caps.maxImageCount);
    info.imageFormat = selected->format;
    info.imageColorSpace = selected->colorSpace;
    info.imageExtent = extent;
    info.imageArrayLayers = 1;
    info.imageUsage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
    info.preTransform = caps.currentTransform;
    info.compositeAlpha = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
    if (!(caps.supportedCompositeAlpha & info.compositeAlpha)) {
      info.compositeAlpha =
          static_cast<VkCompositeAlphaFlagBitsKHR>(caps.supportedCompositeAlpha & -caps.supportedCompositeAlpha);
    }
    info.presentMode = VK_PRESENT_MODE_FIFO_KHR;
    info.clipped = VK_TRUE;
    check(vk.CreateSwapchainKHR(device, &info, nullptr, &swapchain));
    format = selected->format;
    hdrActive = hdr;
    uint32_t count = 0;
    check(vk.GetSwapchainImagesKHR(device, swapchain, &count, nullptr));
    if (!count || count > 16) throw std::runtime_error("Unbounded swapchain");
    images.resize(count);
    check(vk.GetSwapchainImagesKHR(device, swapchain, &count, images.data()));
    VkAttachmentDescription attachment{};
    attachment.format = format;
    attachment.samples = VK_SAMPLE_COUNT_1_BIT;
    attachment.loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR;
    attachment.storeOp = VK_ATTACHMENT_STORE_OP_STORE;
    attachment.stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE;
    attachment.stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
    attachment.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    attachment.finalLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
    VkAttachmentReference reference{0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL};
    VkSubpassDescription subpass{};
    subpass.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS;
    subpass.colorAttachmentCount = 1;
    subpass.pColorAttachments = &reference;
    VkSubpassDependency dependency{
        VK_SUBPASS_EXTERNAL,
        0,
        VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        0,
        VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
        0};
    auto pass = structure<VkRenderPassCreateInfo>(VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO);
    pass.attachmentCount = 1;
    pass.pAttachments = &attachment;
    pass.subpassCount = 1;
    pass.pSubpasses = &subpass;
    pass.dependencyCount = 1;
    pass.pDependencies = &dependency;
    check(vk.CreateRenderPass(device, &pass, nullptr, &renderPass));
    for (auto image : images) {
      auto view = structure<VkImageViewCreateInfo>(VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO);
      view.image = image;
      view.viewType = VK_IMAGE_VIEW_TYPE_2D;
      view.format = format;
      view.subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
      VkImageView created = VK_NULL_HANDLE;
      check(vk.CreateImageView(device, &view, nullptr, &created));
      views.push_back(created);
      auto buffer = structure<VkFramebufferCreateInfo>(VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO);
      buffer.renderPass = renderPass;
      buffer.attachmentCount = 1;
      buffer.pAttachments = &created;
      buffer.width = extent.width;
      buffer.height = extent.height;
      buffer.layers = 1;
      VkFramebuffer frame = VK_NULL_HANDLE;
      check(vk.CreateFramebuffer(device, &buffer, nullptr, &frame));
      framebuffers.push_back(frame);
      auto semaphore = structure<VkSemaphoreCreateInfo>(VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO);
      VkSemaphore signal = VK_NULL_HANDLE;
      check(vk.CreateSemaphore(device, &semaphore, nullptr, &signal));
      finished.push_back(signal);
    }
    VkShaderModule vertex = VK_NULL_HANDLE, fragment = VK_NULL_HANDLE;
    try {
      auto shader = structure<VkShaderModuleCreateInfo>(VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO);
      shader.pCode = kSteamVideoVertex;
      shader.codeSize = sizeof(kSteamVideoVertex);
      check(vk.CreateShaderModule(device, &shader, nullptr, &vertex));
      shader.pCode = kSteamVideoFragment;
      shader.codeSize = sizeof(kSteamVideoFragment);
      check(vk.CreateShaderModule(device, &shader, nullptr, &fragment));
      VkPipelineShaderStageCreateInfo stages[2]{};
      for (auto& stage : stages) {
        stage.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
        stage.pName = "main";
      }
      stages[0].stage = VK_SHADER_STAGE_VERTEX_BIT;
      stages[0].module = vertex;
      stages[1].stage = VK_SHADER_STAGE_FRAGMENT_BIT;
      stages[1].module = fragment;
      auto vertices =
          structure<VkPipelineVertexInputStateCreateInfo>(VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO);
      auto assembly = structure<VkPipelineInputAssemblyStateCreateInfo>(
          VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO);
      assembly.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
      auto viewport =
          structure<VkPipelineViewportStateCreateInfo>(VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO);
      viewport.viewportCount = viewport.scissorCount = 1;
      auto raster =
          structure<VkPipelineRasterizationStateCreateInfo>(VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO);
      raster.polygonMode = VK_POLYGON_MODE_FILL;
      raster.lineWidth = 1.0f;
      auto multisample =
          structure<VkPipelineMultisampleStateCreateInfo>(VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO);
      multisample.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT;
      VkPipelineColorBlendAttachmentState blendAttachment{};
      blendAttachment.colorWriteMask = 15;
      auto blend =
          structure<VkPipelineColorBlendStateCreateInfo>(VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO);
      blend.attachmentCount = 1;
      blend.pAttachments = &blendAttachment;
      VkDynamicState dynamicStates[] = {VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR};
      auto dynamic = structure<VkPipelineDynamicStateCreateInfo>(VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO);
      dynamic.dynamicStateCount = 2;
      dynamic.pDynamicStates = dynamicStates;
      auto graphics = structure<VkGraphicsPipelineCreateInfo>(VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO);
      graphics.stageCount = 2;
      graphics.pStages = stages;
      graphics.pVertexInputState = &vertices;
      graphics.pInputAssemblyState = &assembly;
      graphics.pViewportState = &viewport;
      graphics.pRasterizationState = &raster;
      graphics.pMultisampleState = &multisample;
      graphics.pColorBlendState = &blend;
      graphics.pDynamicState = &dynamic;
      graphics.layout = pipelineLayout;
      graphics.renderPass = renderPass;
      check(vk.CreateGraphicsPipelines(device, VK_NULL_HANDLE, 1, &graphics, nullptr, &pipeline));
    } catch (...) {
      if (vertex) vk.DestroyShaderModule(device, vertex, nullptr);
      if (fragment) vk.DestroyShaderModule(device, fragment, nullptr);
      throw;
    }
    vk.DestroyShaderModule(device, vertex, nullptr);
    vk.DestroyShaderModule(device, fragment, nullptr);
  }
  PyrowaveDecodeStatus present(const uint8_t* bytes, size_t length, int outputWidth, int outputHeight) {
    PyrowaveFrameInfo info;
    if (failed || !pyro || !parsePyrowaveFrame(bytes, length, width, height, info, true, hdrSupported))
      return PyrowaveDecodeStatus::invalid;
    check(vk.WaitForFences(device, 1, &fence, VK_TRUE, kGpuTimeout));
    if (!decoder || chroma444 != info.chroma444) createPlanes(info.chroma444);
    if (pyrowave_decoder_push_packet(decoder, bytes, length) != PYROWAVE_SUCCESS) return PyrowaveDecodeStatus::invalid;
    if (!pyrowave_decoder_decode_is_ready(decoder, false) || outputWidth <= 0 || outputHeight <= 0)
      return PyrowaveDecodeStatus::pending;
    if (!swapchain || hdrActive != info.hdr10 || extent.width != uint32_t(outputWidth) ||
        extent.height != uint32_t(outputHeight))
      createSwapchain(outputWidth, outputHeight, info.hdr10);
    uint32_t index = 0;
    VkResult acquire = vk.AcquireNextImageKHR(device, swapchain, 16000000, acquired, VK_NULL_HANDLE, &index);
    if (acquire == VK_TIMEOUT || acquire == VK_NOT_READY) return PyrowaveDecodeStatus::pending;
    if (acquire == VK_ERROR_OUT_OF_DATE_KHR) {
      createSwapchain(outputWidth, outputHeight, info.hdr10);
      return PyrowaveDecodeStatus::pending;
    }
    if (acquire != VK_SUBOPTIMAL_KHR) check(acquire);
    if (index >= images.size()) return PyrowaveDecodeStatus::invalid;
    check(vk.ResetCommandPool(device, commandPool, 0));
    auto begin = structure<VkCommandBufferBeginInfo>(VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO);
    begin.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    check(vk.BeginCommandBuffer(command, &begin));
    std::array<VkImageMemoryBarrier, 3> barriers{};
    pyrowave_gpu_buffers buffers{};
    for (uint32_t i = 0; i < 3; ++i) {
      auto& barrier = barriers[i];
      barrier.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
      barrier.oldLayout = VK_IMAGE_LAYOUT_UNDEFINED;
      barrier.newLayout = VK_IMAGE_LAYOUT_GENERAL;
      barrier.srcQueueFamilyIndex = barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
      barrier.dstAccessMask = VK_ACCESS_SHADER_WRITE_BIT;
      barrier.image = planes[i].image;
      barrier.subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
      auto& output = buffers.planes[i];
      output.image = planes[i].image;
      output.width = planes[i].width;
      output.height = planes[i].height;
      output.image_format = output.view_format = VK_FORMAT_R16_UNORM;
      output.aspect = VK_IMAGE_ASPECT_COLOR_BIT;
      output.swizzle = VK_COMPONENT_SWIZZLE_IDENTITY;
      output.layout = VK_IMAGE_LAYOUT_GENERAL;
    }
    vk.CmdPipelineBarrier(
        command, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, 0, 0, nullptr, 0, nullptr, 3,
        barriers.data());
    // Let Pyrowave own its upload/decode submission lifetime. A binary
    // semaphore orders its writes before sampling on our render submission.
    check(vk.EndCommandBuffer(command));
    check(vk.ResetFences(device, 1, &fence));
    auto prepare = structure<VkSubmitInfo>(VK_STRUCTURE_TYPE_SUBMIT_INFO);
    prepare.commandBufferCount = 1;
    prepare.pCommandBuffers = &command;
    check(vk.QueueSubmit(queue, 1, &prepare, fence));
    check(vk.WaitForFences(device, 1, &fence, VK_TRUE, kGpuTimeout));
    pyrowave_gpu_sync_operation release{};
    release.sync.semaphore = decoded;
    if (pyrowave_decoder_decode_gpu_buffer(decoder, nullptr, &release, &buffers) != PYROWAVE_SUCCESS)
      return PyrowaveDecodeStatus::invalid;
    check(vk.ResetCommandPool(device, commandPool, 0));
    check(vk.BeginCommandBuffer(command, &begin));
    for (auto& barrier : barriers) {
      barrier.oldLayout = VK_IMAGE_LAYOUT_GENERAL;
      barrier.srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT;
      barrier.dstAccessMask = VK_ACCESS_SHADER_READ_BIT;
    }
    vk.CmdPipelineBarrier(
        command, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, nullptr, 0, nullptr,
        3, barriers.data());
    auto pass = structure<VkRenderPassBeginInfo>(VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO);
    pass.renderPass = renderPass;
    pass.framebuffer = framebuffers[index];
    pass.renderArea.extent = extent;
    VkClearValue black{};
    black.color.float32[3] = 1.0f;
    pass.clearValueCount = 1;
    pass.pClearValues = &black;
    vk.CmdBeginRenderPass(command, &pass, VK_SUBPASS_CONTENTS_INLINE);
    // Fit rather than stretch, even before Flutter has received the video size.
    float scale = std::min(float(extent.width) / width, float(extent.height) / height);
    VkViewport viewport{
        (extent.width - width * scale) * 0.5f,
        (extent.height - height * scale) * 0.5f,
        width * scale,
        height * scale,
        0.0f,
        1.0f};
    VkRect2D scissor{{0, 0}, extent};
    vk.CmdSetViewport(command, 0, 1, &viewport);
    vk.CmdSetScissor(command, 0, 1, &scissor);
    vk.CmdBindPipeline(command, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
    vk.CmdBindDescriptorSets(command, VK_PIPELINE_BIND_POINT_GRAPHICS, pipelineLayout, 0, 1, &descriptors, 0, nullptr);
    const float unit = info.hdr10 ? 4.0f / 1023.0f : 1.0f / 255.0f;
    const float color[8] = {
        info.fullRange ? 0.0f : 16.0f * unit,
        info.fullRange ? 1.0f : 1.0f / (219.0f * unit),
        info.fullRange ? 1.0f : 1.0f / (224.0f * unit),
        info.hdr10 ? 1.0f : 0.0f,
        !info.chroma444 && info.chromaLeft ? 0.5f / width : 0.0f,
        0.0f,
        info.hdr10 ? 512.0f / 1023.0f : 128.0f / 255.0f,
        0.0f};
    vk.CmdPushConstants(command, pipelineLayout, VK_SHADER_STAGE_FRAGMENT_BIT, 0, sizeof(color), color);
    vk.CmdDraw(command, 3, 1, 0, 0);
    vk.CmdEndRenderPass(command);
    check(vk.EndCommandBuffer(command));
    check(vk.ResetFences(device, 1, &fence));
    const VkPipelineStageFlags waitStages[] = {
        VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT};
    const VkSemaphore waitSemaphores[] = {acquired, decoded};
    auto submit = structure<VkSubmitInfo>(VK_STRUCTURE_TYPE_SUBMIT_INFO);
    submit.waitSemaphoreCount = 2;
    submit.pWaitSemaphores = waitSemaphores;
    submit.pWaitDstStageMask = waitStages;
    submit.commandBufferCount = 1;
    submit.pCommandBuffers = &command;
    submit.signalSemaphoreCount = 1;
    submit.pSignalSemaphores = &finished[index];
    check(vk.QueueSubmit(queue, 1, &submit, fence));
    auto present = structure<VkPresentInfoKHR>(VK_STRUCTURE_TYPE_PRESENT_INFO_KHR);
    present.waitSemaphoreCount = 1;
    present.pWaitSemaphores = &finished[index];
    present.swapchainCount = 1;
    present.pSwapchains = &swapchain;
    present.pImageIndices = &index;
    auto result = vk.QueuePresentKHR(queue, &present);
    check(vk.WaitForFences(device, 1, &fence, VK_TRUE, kGpuTimeout));
    if (result == VK_ERROR_OUT_OF_DATE_KHR || result == VK_SUBOPTIMAL_KHR) {
      createSwapchain(outputWidth, outputHeight, info.hdr10);
      return PyrowaveDecodeStatus::pending;
    }
    check(result);
    return PyrowaveDecodeStatus::frame;
  }
};
VulkanPresenter::VulkanPresenter() : impl_(std::make_unique<Impl>()) {}
VulkanPresenter::~VulkanPresenter() = default;
bool VulkanPresenter::open(GpuWindow window, bool allowHdr10) {
  impl_ = std::make_unique<Impl>();
  try {
    return impl_->open(window, allowHdr10);
  } catch (...) {
    return false;
  }
}
bool VulkanPresenter::supportsHdr10() const { return impl_->hdrSupported; }
bool VulkanPresenter::hdr10Active() const { return impl_->hdrActive; }
bool VulkanPresenter::configure(int width, int height, const uint8_t* initial, size_t length) {
  if (impl_->failed || !impl_->pyro || width < 2 || height < 2 || width > 1920 || height > 1080 || (width & 1) ||
      (height & 1) || length > 65536 || (length && !initial))
    return false;
  PyrowaveFrameInfo info;
  if (length && !parsePyrowaveFrame(initial, length, width, height, info, true, impl_->hdrSupported)) return false;
  try {
    check(impl_->vk.WaitForFences(impl_->device, 1, &impl_->fence, VK_TRUE, kGpuTimeout));
    impl_->destroyPlanes();
    impl_->width = width;
    impl_->height = height;
    impl_->initial.clear();
    if (length) impl_->initial.assign(initial, initial + length);
    return true;
  } catch (...) {
    return false;
  }
}
PyrowaveDecodeStatus VulkanPresenter::present(const uint8_t* bytes, size_t length, int width, int height) {
  try {
    return impl_->present(bytes, length, width, height);
  } catch (...) {
    impl_->failed = true;
    return PyrowaveDecodeStatus::invalid;
  }
}
}  // namespace plezy::steam
#else
namespace plezy::steam {
struct VulkanPresenter::Impl {};
VulkanPresenter::VulkanPresenter() : impl_(std::make_unique<Impl>()) {}
VulkanPresenter::~VulkanPresenter() = default;
bool VulkanPresenter::open(GpuWindow, bool) { return false; }
bool VulkanPresenter::supportsHdr10() const { return false; }
bool VulkanPresenter::hdr10Active() const { return false; }
bool VulkanPresenter::configure(int, int, const uint8_t*, size_t) { return false; }
PyrowaveDecodeStatus VulkanPresenter::present(const uint8_t*, size_t, int, int) {
  return PyrowaveDecodeStatus::invalid;
}
}  // namespace plezy::steam
#endif
