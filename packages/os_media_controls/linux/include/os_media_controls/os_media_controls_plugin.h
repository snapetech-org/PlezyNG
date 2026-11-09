#ifndef FLUTTER_PLUGIN_OS_MEDIA_CONTROLS_PLUGIN_H_
#define FLUTTER_PLUGIN_OS_MEDIA_CONTROLS_PLUGIN_H_

#include <flutter_linux/flutter_linux.h>
#include <gio/gio.h>

#include <memory>
#include <string>
#include <map>
#include <vector>

G_BEGIN_DECLS

#ifdef FLUTTER_PLUGIN_IMPL
#define FLUTTER_PLUGIN_EXPORT __attribute__((visibility("default")))
#else
#define FLUTTER_PLUGIN_EXPORT
#endif

typedef struct _OsMediaControlsPlugin OsMediaControlsPlugin;
typedef struct {
  GObjectClass parent_class;
} OsMediaControlsPluginClass;

FLUTTER_PLUGIN_EXPORT GType os_media_controls_plugin_get_type();

FLUTTER_PLUGIN_EXPORT void os_media_controls_plugin_register_with_registrar(
    FlPluginRegistrar* registrar);

G_END_DECLS

// C++ implementation class
namespace os_media_controls {

class OsMediaControlsPluginImpl {
 public:
  OsMediaControlsPluginImpl(FlPluginRegistrar* registrar,
                            FlEventChannel* event_channel);
  ~OsMediaControlsPluginImpl();

  // Disallow copy and assign.
  OsMediaControlsPluginImpl(const OsMediaControlsPluginImpl&) = delete;
  OsMediaControlsPluginImpl& operator=(const OsMediaControlsPluginImpl&) = delete;

  void HandleMethodCall(FlMethodCall* method_call);
  void StartListening();
  void StopListening();
  void SendEvent(FlValue* event);

 private:
  // MPRIS D-Bus interface
  GDBusConnection* connection_;
  guint bus_id_;
  guint media_player_registration_id_;
  guint root_interface_registration_id_;
  GDBusNodeInfo* introspection_data_;
  bool mpris_initialized_;  // Track if MPRIS initialization succeeded

  // Event channel for sending events to Dart
  FlEventChannel* event_channel_;
  bool is_listening_;

  // Current state
  std::string playback_status_;  // "Playing", "Paused", "Stopped"
  double position_;  // Position in microseconds
  double rate_;  // Playback rate
  std::map<std::string, std::string> metadata_;
  std::vector<uint8_t> artwork_data_;
  std::string artwork_path_;
  std::string artwork_dir_;  // Directory for storing artwork files

  // Control capabilities
  bool can_play_;
  bool can_pause_;
  bool can_stop_;
  bool can_go_next_;
  bool can_go_previous_;
  bool can_seek_;
  bool can_quit_;
  bool can_raise_;
  bool has_track_list_;
  std::string identity_;
  std::vector<std::string> supported_uri_schemes_;
  std::vector<std::string> supported_mime_types_;

  // Skip intervals
  int skip_forward_interval_;
  int skip_backward_interval_;

  // Helper methods for plugin functionality
  void SetMetadata(FlValue* args);
  void SetPlaybackState(FlValue* args);
  void EnableControls(FlValue* args);
  void DisableControls(FlValue* args);
  void SetSkipIntervals(FlValue* args);
  void SetQueueInfo(FlValue* args);
  void Clear();

  // MPRIS-specific helper methods
  void InitializeMPRIS();
  void CleanupMPRIS();
  void UpdateMPRISProperties();
  void UpdateMetadataProperty();
  void UpdatePlaybackStatusProperty();
  void UpdatePositionProperty();
  void UpdateRateProperty();
  void UpdateCanControlProperties();

  // D-Bus handler methods
  static void HandleMethodCallDBus(
      GDBusConnection* connection,
      const gchar* sender,
      const gchar* object_path,
      const gchar* interface_name,
      const gchar* method_name,
      GVariant* parameters,
      GDBusMethodInvocation* invocation,
      gpointer user_data);

  static GVariant* HandleGetProperty(
      GDBusConnection* connection,
      const gchar* sender,
      const gchar* object_path,
      const gchar* interface_name,
      const gchar* property_name,
      GError** error,
      gpointer user_data);

  static gboolean HandleSetProperty(
      GDBusConnection* connection,
      const gchar* sender,
      const gchar* object_path,
      const gchar* interface_name,
      const gchar* property_name,
      GVariant* value,
      GError** error,
      gpointer user_data);

  // Helper methods
  std::string GetStringFromFlValue(FlValue* map, const char* key);
  double GetDoubleFromFlValue(FlValue* map, const char* key);
  int64_t GetInt64FromFlValue(FlValue* map, const char* key);
  std::vector<uint8_t> GetBytesFromFlValue(FlValue* map, const char* key);
  GVariant* SafeVariantNewString(const std::string& str);
  std::string SaveArtworkToFile(const std::vector<uint8_t>& data);
  void CreateArtworkDirectory();
  void CleanupArtworkFile(const std::string& path);
  void CleanupArtworkDirectory();
  void EmitPropertiesChanged(const char* interface_name,
                             GVariantBuilder* changed_properties_builder);
};

}  // namespace os_media_controls

#endif  // FLUTTER_PLUGIN_OS_MEDIA_CONTROLS_PLUGIN_H_
