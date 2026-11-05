// SPDX-License-Identifier: GPL-3.0-or-later
// Software-rendered libretro host. Every core call runs on one Dart worker
// isolate. The audio device is the only native callback thread.
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <filesystem>
#include <map>
#include <mutex>
#include <string>
#include <vector>
#include "libretro.h"
#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio.h"
#ifdef _WIN32
#include <windows.h>
#define API extern "C" __declspec(dllexport)
using Module = HMODULE;
static Module module_open(const char* path) {
  const int size=MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,path,-1,nullptr,0);
  if(size<=0)return nullptr;std::vector<wchar_t> wide(static_cast<size_t>(size));
  if(!MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,path,-1,wide.data(),size))return nullptr;
  return LoadLibraryW(wide.data());
}
static void* symbol(Module m, const char* n) { return reinterpret_cast<void*>(GetProcAddress(m,n)); }
static void module_close(Module m) { FreeLibrary(m); }
#else
#include <dlfcn.h>
#define API extern "C" __attribute__((visibility("default")))
using Module = void*;
static Module module_open(const char* path) { return dlopen(path,RTLD_NOW|RTLD_LOCAL); }
static void* symbol(Module m, const char* n) { return dlsym(m,n); }
static void module_close(Module m) { dlclose(m); }
#endif
namespace {
struct Host {
  Module module{};
  void (*init)(){}; void (*deinit)(){}; unsigned (*api_version)(){};
  void (*get_system_info)(retro_system_info*){};
  void (*get_system_av_info)(retro_system_av_info*){};
  bool (*load_game)(const retro_game_info*){};
  void (*unload_game)(){}; void (*run)(){};
  size_t (*serialize_size)(){}; bool (*serialize)(void*,size_t){};
  bool (*unserialize)(const void*,size_t){};
  void* (*get_memory_data)(unsigned){}; size_t (*get_memory_size)(unsigned){};
  void (*set_environment)(retro_environment_t){};
  void (*set_video_refresh)(retro_video_refresh_t){};
  void (*set_audio_sample)(retro_audio_sample_t){};
  void (*set_audio_sample_batch)(retro_audio_sample_batch_t){};
  void (*set_input_poll)(retro_input_poll_t){};
  void (*set_input_state)(retro_input_state_t){};
  void (*set_controller_port_device)(unsigned,unsigned){};
  std::string system_dir, save_dir, path, identity;
  std::map<std::string,std::string> variables;
  std::vector<uint8_t> rom, frame, snapshot;
  uint32_t width=0,height=0,pixel_format=RETRO_PIXEL_FORMAT_0RGB1555;
  uint16_t buttons[4]{};
  double fps=60,aspect=0;
  bool initialized=false, loaded=false, audio_started=false;
  bool audio_paused=true;
  ma_device device{};
  std::mutex audio_mutex;
  std::vector<int16_t> audio=std::vector<int16_t>(32768);
  size_t read=0,write=0;
};
Host* host=nullptr;
std::atomic<bool> claimed{false};
bool environment(unsigned command, void* data) {
  if (!host) return false;
  switch(command) {
    case RETRO_ENVIRONMENT_GET_CAN_DUPE: *static_cast<bool*>(data)=true; return true;
    case RETRO_ENVIRONMENT_SET_PIXEL_FORMAT: {
      const auto format=*static_cast<unsigned*>(data);
      if (format>RETRO_PIXEL_FORMAT_RGB565) return false;
      host->pixel_format=format; return true;
    }
    case RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY: *static_cast<const char**>(data)=host->system_dir.c_str(); return true;
    case RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY: *static_cast<const char**>(data)=host->save_dir.c_str(); return true;
    case RETRO_ENVIRONMENT_GET_VARIABLE: {
      auto* variable=static_cast<retro_variable*>(data);
      const auto found=host->variables.find(variable->key?variable->key:"");
      variable->value=found==host->variables.end()?nullptr:found->second.c_str();
      return variable->value!=nullptr;
    }
    case RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE: *static_cast<bool*>(data)=false; return true;
    case RETRO_ENVIRONMENT_SET_VARIABLES: {
      host->variables.clear();
      const auto* variable=static_cast<const retro_variable*>(data);
      if(!variable)return false;
      for(size_t n=0;n<256 && variable[n].key;n++) {
        if(!variable[n].value)continue;
        const std::string value=variable[n].value;
        const auto start=value.find("; ");
        if(start==std::string::npos)continue;
        const auto end=value.find('|',start+2);
        host->variables.emplace(variable[n].key,value.substr(start+2,end==std::string::npos?end:end-start-2));
      }
      return true;
    }
    case RETRO_ENVIRONMENT_SET_INPUT_DESCRIPTORS: return true;
    case RETRO_ENVIRONMENT_SET_SUPPORT_NO_GAME: return true;
    case RETRO_ENVIRONMENT_GET_INPUT_BITMASKS: return true;
    case RETRO_ENVIRONMENT_SET_GEOMETRY: {
      const auto aspect=static_cast<retro_game_geometry*>(data)->aspect_ratio;
      host->aspect=std::isfinite(aspect)&&aspect>0&&aspect<=8?aspect:0;
      return true;
    }
    case RETRO_ENVIRONMENT_GET_AUDIO_VIDEO_ENABLE: *static_cast<int*>(data)=3; return true;
    default: return false; // In particular: no HW context, executable or VFS access.
  }
}
void video(const void* data,unsigned width,unsigned height,size_t pitch) {
  if (!host || !data || data==RETRO_HW_FRAME_BUFFER_VALID || width==0 || height==0 || width>2048 || height>2048) return;
  const unsigned bpp=host->pixel_format==RETRO_PIXEL_FORMAT_XRGB8888 ? 4:2;
  if (pitch<width*bpp || pitch>16*1024*1024) return;
  host->frame.resize(static_cast<size_t>(width)*height*4);
  host->width=width; host->height=height;
  for (unsigned y=0;y<height;y++) {
    const auto* src=static_cast<const uint8_t*>(data)+y*pitch;
    auto* dst=host->frame.data()+static_cast<size_t>(y)*width*4;
    for (unsigned x=0;x<width;x++) {
      uint32_t color=0; std::memcpy(&color,src+x*bpp,bpp);
      if(bpp==4) { dst[x*4]=static_cast<uint8_t>(color>>16);dst[x*4+1]=static_cast<uint8_t>(color>>8);dst[x*4+2]=static_cast<uint8_t>(color); }
      else {
        const bool rgb565=host->pixel_format==RETRO_PIXEL_FORMAT_RGB565;
        const unsigned r=(color>>(rgb565?11:10))&31,g=(color>>5)&(rgb565?63:31),b=color&31;
        dst[x*4]=static_cast<uint8_t>((r<<3)|(r>>2));
        dst[x*4+1]=static_cast<uint8_t>(rgb565?((g<<2)|(g>>4)):((g<<3)|(g>>2)));
        dst[x*4+2]=static_cast<uint8_t>((b<<3)|(b>>2));
      }
      dst[x*4+3]=255;
    }
  }
}
size_t audio_batch(const int16_t* data,size_t frames) {
  if(!host || !data) return frames;
  std::lock_guard<std::mutex> lock(host->audio_mutex);
  if(host->audio_paused) return frames;
  for(size_t n=0;n<frames;n++) {
    // Keep stereo frames together even when the queue overruns. Dropping one
    // sample swaps left/right channels until the next pause flush.
    const auto next=(host->write+2)%host->audio.size();
    if(next==host->read) host->read=(host->read+2)%host->audio.size();
    host->audio[host->write]=data[n*2];host->audio[host->write+1]=data[n*2+1];host->write=next;
  }
  return frames;
}
void audio_sample(int16_t l,int16_t r) { const int16_t data[]={l,r};audio_batch(data,1); }
void audio_callback(ma_device* device,void* out,const void*,ma_uint32 frames) {
  auto* h=static_cast<Host*>(device->pUserData);auto* dst=static_cast<int16_t*>(out);
  std::lock_guard<std::mutex> lock(h->audio_mutex);
  for(size_t n=0;n<static_cast<size_t>(frames)*2;n++) {
    dst[n]=h->audio_paused||h->read==h->write?0:h->audio[h->read];
    if(h->read!=h->write) h->read=(h->read+1)%h->audio.size();
  }
}
void poll() {}
int16_t input(unsigned port,unsigned device,unsigned,unsigned id) {
  if(!host || port>=4 || (device&RETRO_DEVICE_MASK)!=RETRO_DEVICE_JOYPAD) return 0;
  if(id==RETRO_DEVICE_ID_JOYPAD_MASK) return static_cast<int16_t>(host->buttons[port]);
  return id<16 && (host->buttons[port]&(1u<<id)) ? 1:0;
}
void cleanup() {
  if(!host) return;
  if(host->audio_started) { ma_device_uninit(&host->device);host->audio_started=false; }
  if(host->loaded) host->unload_game();
  if(host->initialized) host->deinit();
  if(host->module) module_close(host->module);
  delete host;host=nullptr;claimed.store(false);
}
}
API void* plezy_retro_alloc(int size) { return size>0 && size<=134217728 ? std::malloc(static_cast<size_t>(size)):nullptr; }
API void plezy_retro_free(void* data) { std::free(data); }
API int plezy_retro_has_core(const char* path) {
  if(claimed.load()) return 0;
  auto module=module_open(path);if(!module) return 0;
  const bool valid=symbol(module,"retro_run") && symbol(module,"retro_load_game") && symbol(module,"retro_api_version");
  module_close(module);return valid?1:0;
}
API void plezy_retro_close() { cleanup(); }
API int plezy_retro_open(const char* core,const char* rom,const char* system,const char* saves) {
  bool expected=false;if(!claimed.compare_exchange_strong(expected,true)) return 0;
  host=new Host();host->path=rom;host->system_dir=system;host->save_dir=saves;host->module=module_open(core);
  if(!host->module) {cleanup();return 0;}
#define LOAD(name) host->name=reinterpret_cast<decltype(host->name)>(symbol(host->module,"retro_" #name)); if(!host->name){cleanup();return 0;}
  LOAD(init) LOAD(deinit) LOAD(api_version) LOAD(get_system_info) LOAD(get_system_av_info) LOAD(load_game) LOAD(unload_game) LOAD(run)
  LOAD(serialize_size) LOAD(serialize) LOAD(unserialize) LOAD(get_memory_data) LOAD(get_memory_size)
  LOAD(set_environment) LOAD(set_video_refresh) LOAD(set_audio_sample) LOAD(set_audio_sample_batch) LOAD(set_input_poll) LOAD(set_input_state) LOAD(set_controller_port_device)
#undef LOAD
  if(host->api_version()!=RETRO_API_VERSION) {cleanup();return 0;}
  host->set_environment(environment);host->set_video_refresh(video);host->set_audio_sample(audio_sample);
  host->set_audio_sample_batch(audio_batch);host->set_input_poll(poll);host->set_input_state(input);
  host->init();host->initialized=true;
  retro_system_info info{};host->get_system_info(&info);
  host->identity=std::string(info.library_name?info.library_name:"")+"/"+(info.library_version?info.library_version:"");
  retro_game_info game{};game.path=host->path.c_str();
  if(!info.need_fullpath) {
    std::ifstream input(std::filesystem::u8path(host->path),std::ios::binary|std::ios::ate);
    const auto size=input.tellg();
    if(!input || size<=0 || size>134217728) {cleanup();return 0;}
    host->rom.resize(static_cast<size_t>(size));input.seekg(0);input.read(reinterpret_cast<char*>(host->rom.data()),size);
    if(!input){cleanup();return 0;}game.data=host->rom.data();game.size=host->rom.size();
  }
  if(!host->load_game(&game)) {cleanup();return 0;}host->loaded=true;
  for(unsigned p=0;p<4;p++) host->set_controller_port_device(p,RETRO_DEVICE_JOYPAD);
  retro_system_av_info av{};host->get_system_av_info(&av);
  host->aspect=std::isfinite(av.geometry.aspect_ratio)&&av.geometry.aspect_ratio>0&&av.geometry.aspect_ratio<=8?av.geometry.aspect_ratio:0;
  host->fps=std::isfinite(av.timing.fps)?std::clamp(av.timing.fps,15.0,120.0):60.0;
  if(!std::isfinite(av.timing.sample_rate)||av.timing.sample_rate<8000||av.timing.sample_rate>192000){cleanup();return 0;}
  auto config=ma_device_config_init(ma_device_type_playback);config.playback.format=ma_format_s16;config.playback.channels=2;
  config.sampleRate=static_cast<ma_uint32>(av.timing.sample_rate);config.dataCallback=audio_callback;config.pUserData=host;
  if(ma_device_init(nullptr,&config,&host->device)!=MA_SUCCESS){cleanup();return 0;}
  host->audio_started=true;if(ma_device_start(&host->device)!=MA_SUCCESS){cleanup();return 0;}
  return 1;
}
API void plezy_retro_run() { if(host&&host->loaded) host->run(); }
API double plezy_retro_fps() {return host?host->fps:60;}
API double plezy_retro_aspect() {return host?host->aspect:0;}
API const char* plezy_retro_identity() { return host?host->identity.c_str():""; }
API int plezy_retro_width(){return host?static_cast<int>(host->width):0;}
API int plezy_retro_height(){return host?static_cast<int>(host->height):0;}
API const uint8_t* plezy_retro_frame(){return host&&!host->frame.empty()?host->frame.data():nullptr;}
API void plezy_retro_buttons(int port,int buttons){if(host&&port>=0&&port<4)host->buttons[port]=static_cast<uint16_t>(buttons);}
API void plezy_retro_pause_audio(int paused) {
  if(!host)return;
  std::lock_guard<std::mutex> lock(host->audio_mutex);
  host->audio_paused=paused!=0;host->read=host->write;
}
API int plezy_retro_capture(int kind) {
  if(!host||!host->loaded||kind<0||kind>2)return 0;
  const bool state=kind==1;const unsigned memory=kind==2?RETRO_MEMORY_RTC:RETRO_MEMORY_SAVE_RAM;
  size_t size=state?host->serialize_size():host->get_memory_size(memory);
  if(!size||size>134217728)return 0;host->snapshot.resize(size);
  if(state){if(!host->serialize(host->snapshot.data(),size))return 0;}
  else {auto* data=host->get_memory_data(memory);if(!data)return 0;std::memcpy(host->snapshot.data(),data,size);}
  return static_cast<int>(size);
}
API const uint8_t* plezy_retro_snapshot(){return host&&!host->snapshot.empty()?host->snapshot.data():nullptr;}
API int plezy_retro_restore(const uint8_t* bytes,int size,int kind) {
  if(!host||!host->loaded||!bytes||size<=0||size>134217728||kind<0||kind>2)return 0;
  if(kind==1)return host->unserialize(bytes,static_cast<size_t>(size))?1:0;
  const unsigned memory=kind==2?RETRO_MEMORY_RTC:RETRO_MEMORY_SAVE_RAM;
  const auto expected=host->get_memory_size(memory);auto* destination=host->get_memory_data(memory);
  if(expected!=static_cast<size_t>(size)||!destination)return 0;std::memcpy(destination,bytes,expected);return 1;
}
