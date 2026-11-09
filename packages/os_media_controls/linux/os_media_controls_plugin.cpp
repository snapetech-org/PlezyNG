#include "os_media_controls/os_media_controls_plugin.h"

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>
#include <sys/utsname.h>
#include <gio/gio.h>

#include <cctype>
#include <cstring>
#include <cmath>
#include <cstdio>
#include <memory>
#include <sstream>
#include <fstream>
#include <iomanip>
#include <chrono>
#include <stdexcept>
#include <unistd.h>

#define OS_MEDIA_CONTROLS_PLUGIN(obj) \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), os_media_controls_plugin_get_type(), \
                               OsMediaControlsPlugin))

struct _OsMediaControlsPlugin {
  GObject parent_instance;
  FlPluginRegistrar* registrar;
  FlMethodChannel* method_channel;
  FlEventChannel* event_channel;
  os_media_controls::OsMediaControlsPluginImpl* impl;
};

G_DEFINE_TYPE(OsMediaControlsPlugin, os_media_controls_plugin, g_object_get_type())

// MPRIS D-Bus introspection XML
static const gchar introspection_xml[] =
  "<node>"
  "  <interface name='org.mpris.MediaPlayer2'>"
  "    <method name='Raise'/>"
  "    <method name='Quit'/>"
  "    <property name='CanQuit' type='b' access='read'/>"
  "    <property name='CanRaise' type='b' access='read'/>"
  "    <property name='HasTrackList' type='b' access='read'/>"
  "    <property name='Identity' type='s' access='read'/>"
  "    <property name='SupportedUriSchemes' type='as' access='read'/>"
  "    <property name='SupportedMimeTypes' type='as' access='read'/>"
  "  </interface>"
  "  <interface name='org.mpris.MediaPlayer2.Player'>"
  "    <method name='Next'/>"
  "    <method name='Previous'/>"
  "    <method name='Pause'/>"
  "    <method name='PlayPause'/>"
  "    <method name='Stop'/>"
  "    <method name='Play'/>"
  "    <method name='Seek'>"
  "      <arg direction='in' name='Offset' type='x'/>"
  "    </method>"
  "    <method name='SetPosition'>"
  "      <arg direction='in' name='TrackId' type='o'/>"
  "      <arg direction='in' name='Position' type='x'/>"
  "    </method>"
  "    <signal name='Seeked'>"
  "      <arg name='Position' type='x'/>"
  "    </signal>"
  "    <property name='PlaybackStatus' type='s' access='read'/>"
  "    <property name='Rate' type='d' access='readwrite'/>"
  "    <property name='Metadata' type='a{sv}' access='read'/>"
  "    <property name='Volume' type='d' access='readwrite'/>"
  "    <property name='Position' type='x' access='read'/>"
  "    <property name='MinimumRate' type='d' access='read'/>"
  "    <property name='MaximumRate' type='d' access='read'/>"
  "    <property name='CanGoNext' type='b' access='read'/>"
  "    <property name='CanGoPrevious' type='b' access='read'/>"
  "    <property name='CanPlay' type='b' access='read'/>"
  "    <property name='CanPause' type='b' access='read'/>"
  "    <property name='CanSeek' type='b' access='read'/>"
  "    <property name='CanControl' type='b' access='read'/>"
  "  </interface>"
  "</node>";

namespace os_media_controls {

std::string SanitizeDBusNameComponent(const char* value) {
  std::string input = value && value[0] != '\0' ? value : "OsMediaControls";
  std::string sanitized;

  for (unsigned char ch : input) {
    if (std::isalnum(ch) || ch == '_') {
      sanitized.push_back(static_cast<char>(ch));
    } else {
      sanitized.push_back('_');
    }
  }

  if (sanitized.empty()) {
    sanitized = "OsMediaControls";
  }

  unsigned char first = static_cast<unsigned char>(sanitized[0]);
  if (!std::isalpha(first) && sanitized[0] != '_') {
    sanitized.insert(sanitized.begin(), '_');
  }

  return sanitized;
}

// Helper to convert FlValue to string
std::string OsMediaControlsPluginImpl::GetStringFromFlValue(FlValue* map, const char* key) {
  if (!map || !key || fl_value_get_type(map) != FL_VALUE_TYPE_MAP) {
    return "";
  }
  FlValue* value = fl_value_lookup_string(map, key);
  if (value && fl_value_get_type(value) == FL_VALUE_TYPE_STRING) {
    const char* str = fl_value_get_string(value);
    if (str) {
      return str;
    }
  }
  return "";
}

// Helper to convert FlValue to double
double OsMediaControlsPluginImpl::GetDoubleFromFlValue(FlValue* map, const char* key) {
  if (!map || !key || fl_value_get_type(map) != FL_VALUE_TYPE_MAP) {
    return 0.0;
  }
  FlValue* value = fl_value_lookup_string(map, key);
  if (value && fl_value_get_type(value) == FL_VALUE_TYPE_FLOAT) {
    double result = fl_value_get_float(value);
    if (std::isfinite(result)) {
      return result;
    }
  }
  return 0.0;
}

// Helper to convert FlValue to int64
int64_t OsMediaControlsPluginImpl::GetInt64FromFlValue(FlValue* map, const char* key) {
  if (!map || !key || fl_value_get_type(map) != FL_VALUE_TYPE_MAP) {
    return 0;
  }
  FlValue* value = fl_value_lookup_string(map, key);
  if (value && fl_value_get_type(value) == FL_VALUE_TYPE_INT) {
    return fl_value_get_int(value);
  }
  return 0;
}

// Helper to get bytes from FlValue
std::vector<uint8_t> OsMediaControlsPluginImpl::GetBytesFromFlValue(FlValue* map, const char* key) {
  if (!map || !key || fl_value_get_type(map) != FL_VALUE_TYPE_MAP) {
    return {};
  }
  FlValue* value = fl_value_lookup_string(map, key);
  if (value && fl_value_get_type(value) == FL_VALUE_TYPE_UINT8_LIST) {
    const uint8_t* data = fl_value_get_uint8_list(value);
    size_t length = fl_value_get_length(value);
    if (data && length > 0) {
      return std::vector<uint8_t>(data, data + length);
    }
  }
  return {};
}

// Helper to safely create GVariant string with UTF-8 validation
// GLib's g_variant_new_string() aborts the program if the input is not valid UTF-8.
// This wrapper validates the string first and returns an empty string on failure.
GVariant* OsMediaControlsPluginImpl::SafeVariantNewString(const std::string& str) {
  if (str.empty()) {
    return g_variant_new_string("");
  }

  // Validate UTF-8
  if (!g_utf8_validate(str.c_str(), -1, nullptr)) {
    g_warning("Invalid UTF-8 string detected, using empty string instead");
    return g_variant_new_string("");
  }

  return g_variant_new_string(str.c_str());
}

// Create artwork directory
void OsMediaControlsPluginImpl::CreateArtworkDirectory() {
  // Use XDG_RUNTIME_DIR for RAM-based temporary storage (auto-cleanup on logout)
  const char* runtime_dir = g_get_user_runtime_dir();
  if (!runtime_dir) {
    // Fallback to /tmp if XDG_RUNTIME_DIR is not available
    runtime_dir = g_get_tmp_dir();
  }

  std::stringstream ss;
  ss << runtime_dir << "/os_media_controls_artwork";
  artwork_dir_ = ss.str();

  // Create directory if it doesn't exist
  g_mkdir_with_parents(artwork_dir_.c_str(), 0700);
}

// Save artwork to file with unique timestamp-based name and return file:// URI
std::string OsMediaControlsPluginImpl::SaveArtworkToFile(const std::vector<uint8_t>& data) {
  if (data.empty() || artwork_dir_.empty()) {
    return "";
  }

  // Verify data pointer is valid
  if (!data.data()) {
    g_warning("SaveArtworkToFile: data pointer is null");
    return "";
  }

  // Generate unique filename with timestamp to prevent caching issues
  auto now = std::chrono::system_clock::now();
  auto timestamp = std::chrono::duration_cast<std::chrono::milliseconds>(
      now.time_since_epoch()).count();

  std::stringstream ss;
  ss << artwork_dir_ << "/artwork_" << timestamp << ".jpg";
  std::string path = ss.str();

  // Write data to file
  std::ofstream file(path, std::ios::binary);
  if (!file.is_open()) {
    g_warning("SaveArtworkToFile: failed to open file '%s'", path.c_str());
    return "";
  }

  file.write(reinterpret_cast<const char*>(data.data()), data.size());

  // Check if write succeeded
  if (!file.good()) {
    g_warning("SaveArtworkToFile: failed to write to file '%s'", path.c_str());
    file.close();
    // Try to remove the partial file
    std::remove(path.c_str());
    return "";
  }

  file.close();

  // Verify close succeeded
  if (file.fail()) {
    g_warning("SaveArtworkToFile: failed to close file '%s'", path.c_str());
    // File might still be usable even if close reports an error
  }

  return "file://" + path;
}

// Clean up a single artwork file
void OsMediaControlsPluginImpl::CleanupArtworkFile(const std::string& path) {
  if (path.empty()) {
    return;
  }

  // Only delete files we created (in our artwork directory)
  if (path.find("file://") == 0) {
    std::string file_path = path.substr(7);
    if (file_path.find(artwork_dir_) == 0) {
      std::remove(file_path.c_str());
    }
  }
}

// Clean up entire artwork directory
void OsMediaControlsPluginImpl::CleanupArtworkDirectory() {
  if (artwork_dir_.empty()) {
    return;
  }

  // Open directory
  GDir* dir = g_dir_open(artwork_dir_.c_str(), 0, nullptr);
  if (!dir) {
    return;
  }

  // Remove all files in the directory
  const char* filename;
  while ((filename = g_dir_read_name(dir)) != nullptr) {
    std::stringstream ss;
    ss << artwork_dir_ << "/" << filename;
    std::remove(ss.str().c_str());
  }

  g_dir_close(dir);

  // Remove the directory itself
  rmdir(artwork_dir_.c_str());
}

// Constructor
OsMediaControlsPluginImpl::OsMediaControlsPluginImpl(FlPluginRegistrar* registrar,
                                                     FlEventChannel* event_channel)
    : connection_(nullptr),
      bus_id_(0),
      media_player_registration_id_(0),
      root_interface_registration_id_(0),
      introspection_data_(nullptr),
      mpris_initialized_(false),
      event_channel_(event_channel ? FL_EVENT_CHANNEL(g_object_ref(event_channel))
                                   : nullptr),
      is_listening_(false),
      playback_status_("Stopped"),
      position_(0),
      rate_(1.0),
      can_play_(true),
      can_pause_(true),
      can_stop_(false),
      can_go_next_(false),
      can_go_previous_(false),
      can_seek_(false),
      can_quit_(false),
      can_raise_(false),
      has_track_list_(false),
      identity_(g_get_application_name() ? g_get_application_name() : "OS Media Controls"),
      supported_uri_schemes_({"file", "http", "https"}),
      supported_mime_types_({"audio/mpeg", "audio/flac", "audio/wav"}),
      skip_forward_interval_(0),
      skip_backward_interval_(0) {
  CreateArtworkDirectory();
  InitializeMPRIS();
}

// Destructor
OsMediaControlsPluginImpl::~OsMediaControlsPluginImpl() {
  if (event_channel_) {
    g_object_unref(event_channel_);
    event_channel_ = nullptr;
  }
  CleanupMPRIS();
  CleanupArtworkDirectory();
}

// Initialize MPRIS D-Bus interface
void OsMediaControlsPluginImpl::InitializeMPRIS() {
  GError* error = nullptr;

  // Get session bus
  connection_ = g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, &error);
  if (error) {
    g_warning("Failed to connect to session bus: %s", error->message);
    g_error_free(error);
    mpris_initialized_ = false;
    return;
  }

  if (!connection_) {
    g_warning("Failed to connect to session bus: connection is null");
    mpris_initialized_ = false;
    return;
  }

  // Parse introspection XML
  introspection_data_ = g_dbus_node_info_new_for_xml(introspection_xml, &error);
  if (error) {
    g_warning("Failed to parse introspection XML: %s", error->message);
    g_error_free(error);
    mpris_initialized_ = false;
    return;
  }

  if (!introspection_data_) {
    g_warning("Failed to parse introspection XML: data is null");
    mpris_initialized_ = false;
    return;
  }

  // Verify we have at least 2 interfaces (MediaPlayer2 and MediaPlayer2.Player)
  if (!introspection_data_->interfaces ||
      !introspection_data_->interfaces[0] ||
      !introspection_data_->interfaces[1]) {
    g_warning("Introspection data does not contain expected interfaces");
    if (introspection_data_) {
      g_dbus_node_info_unref(introspection_data_);
      introspection_data_ = nullptr;
    }
    mpris_initialized_ = false;
    return;
  }

  // Define vtable for handling D-Bus method calls
  static const GDBusInterfaceVTable vtable = {
    HandleMethodCallDBus,
    HandleGetProperty,
    HandleSetProperty
  };

  // Register base MediaPlayer2 interface
  root_interface_registration_id_ = g_dbus_connection_register_object(
      connection_,
      "/org/mpris/MediaPlayer2",
      introspection_data_->interfaces[0],  // MediaPlayer2 interface
      &vtable,
      this,
      nullptr,
      &error);

  if (error) {
    g_warning("Failed to register MediaPlayer2 interface: %s", error->message);
    g_error_free(error);
    mpris_initialized_ = false;
    return;
  }

  if (root_interface_registration_id_ == 0) {
    g_warning("Failed to register MediaPlayer2 interface: registration ID is 0");
    mpris_initialized_ = false;
    return;
  }

  // Register MediaPlayer2.Player interface
  media_player_registration_id_ = g_dbus_connection_register_object(
      connection_,
      "/org/mpris/MediaPlayer2",
      introspection_data_->interfaces[1],  // Player interface
      &vtable,
      this,
      nullptr,
      &error);

  if (error) {
    g_warning("Failed to register MediaPlayer2.Player interface: %s", error->message);
    g_error_free(error);
    mpris_initialized_ = false;
    return;
  }

  if (media_player_registration_id_ == 0) {
    g_warning("Failed to register MediaPlayer2.Player interface: registration ID is 0");
    mpris_initialized_ = false;
    return;
  }

  // Request a bus name that is unique to the host app instead of the plugin.
  const char* app_name = g_get_prgname();
  if (!app_name || app_name[0] == '\0') {
    app_name = g_get_application_name();
  }
  std::string bus_name = "org.mpris.MediaPlayer2." +
      SanitizeDBusNameComponent(app_name);

  bus_id_ = g_bus_own_name_on_connection(
      connection_,
      bus_name.c_str(),
      G_BUS_NAME_OWNER_FLAGS_NONE,
      nullptr,
      nullptr,
      nullptr,
      nullptr);

  // Mark as successfully initialized
  mpris_initialized_ = true;
  g_message("MPRIS interface initialized successfully");
}

// Cleanup MPRIS
void OsMediaControlsPluginImpl::CleanupMPRIS() {
  if (bus_id_ > 0) {
    g_bus_unown_name(bus_id_);
    bus_id_ = 0;
  }

  if (media_player_registration_id_ > 0) {
    g_dbus_connection_unregister_object(connection_, media_player_registration_id_);
    media_player_registration_id_ = 0;
  }

  if (root_interface_registration_id_ > 0) {
    g_dbus_connection_unregister_object(connection_, root_interface_registration_id_);
    root_interface_registration_id_ = 0;
  }

  if (introspection_data_) {
    g_dbus_node_info_unref(introspection_data_);
    introspection_data_ = nullptr;
  }

  if (connection_) {
    g_object_unref(connection_);
    connection_ = nullptr;
  }

  // Clean up current artwork file
  CleanupArtworkFile(artwork_path_);
}

// D-Bus method call handler
void OsMediaControlsPluginImpl::HandleMethodCallDBus(
    GDBusConnection* connection,
    const gchar* sender,
    const gchar* object_path,
    const gchar* interface_name,
    const gchar* method_name,
    GVariant* parameters,
    GDBusMethodInvocation* invocation,
    gpointer user_data) {

  auto* self = static_cast<OsMediaControlsPluginImpl*>(user_data);
  if (!self) {
    g_dbus_method_invocation_return_error(invocation, G_DBUS_ERROR,
                                          G_DBUS_ERROR_FAILED,
                                          "Internal error: null user data");
    return;
  }

  if (!interface_name || !method_name) {
    g_dbus_method_invocation_return_error(invocation, G_DBUS_ERROR,
                                          G_DBUS_ERROR_INVALID_ARGS,
                                          "Invalid arguments");
    return;
  }

  bool is_player_interface =
      g_strcmp0(interface_name, "org.mpris.MediaPlayer2.Player") == 0;
  bool is_root_interface =
      g_strcmp0(interface_name, "org.mpris.MediaPlayer2") == 0;

  if (!is_player_interface && !is_root_interface) {
    g_dbus_method_invocation_return_error(invocation, G_DBUS_ERROR,
                                          G_DBUS_ERROR_UNKNOWN_INTERFACE,
                                          "Unknown interface");
    return;
  }

  if (is_root_interface) {
    if (g_strcmp0(method_name, "Raise") == 0 ||
        g_strcmp0(method_name, "Quit") == 0) {
      g_dbus_method_invocation_return_value(invocation, nullptr);
      return;
    }

    g_dbus_method_invocation_return_error(invocation, G_DBUS_ERROR,
                                          G_DBUS_ERROR_UNKNOWN_METHOD,
                                          "Unknown method");
    return;
  }

  // Create event map to send to Flutter
  g_autoptr(FlValue) event = fl_value_new_map();

  if (g_strcmp0(method_name, "Play") == 0) {
    fl_value_set_string_take(event, "type", fl_value_new_string("play"));
  } else if (g_strcmp0(method_name, "Pause") == 0) {
    fl_value_set_string_take(event, "type", fl_value_new_string("pause"));
  } else if (g_strcmp0(method_name, "PlayPause") == 0) {
    const char* type = (self->playback_status_ == "Playing")
                           ? "pause"
                           : "play";
    fl_value_set_string_take(event, "type", fl_value_new_string(type));
  } else if (g_strcmp0(method_name, "Stop") == 0) {
    fl_value_set_string_take(event, "type", fl_value_new_string("stop"));
  } else if (g_strcmp0(method_name, "Next") == 0) {
    fl_value_set_string_take(event, "type", fl_value_new_string("next"));
  } else if (g_strcmp0(method_name, "Previous") == 0) {
    fl_value_set_string_take(event, "type", fl_value_new_string("previous"));
  } else if (g_strcmp0(method_name, "Seek") == 0) {
    gint64 offset_microseconds;
    g_variant_get(parameters, "(x)", &offset_microseconds);

    // Calculate new position
    double new_position = self->position_ / 1000000.0 + offset_microseconds / 1000000.0;

    fl_value_set_string_take(event, "type", fl_value_new_string("seek"));
    fl_value_set_string_take(event, "position", fl_value_new_float(new_position));
  } else if (g_strcmp0(method_name, "SetPosition") == 0) {
    const gchar* track_id;
    gint64 position_microseconds;
    g_variant_get(parameters, "(&ox)", &track_id, &position_microseconds);

    double position_seconds = position_microseconds / 1000000.0;

    fl_value_set_string_take(event, "type", fl_value_new_string("seek"));
    fl_value_set_string_take(event, "position", fl_value_new_float(position_seconds));
  } else {
    g_dbus_method_invocation_return_error(invocation, G_DBUS_ERROR,
                                          G_DBUS_ERROR_UNKNOWN_METHOD,
                                          "Unknown method");
    return;
  }

  // Send event to Flutter
  self->SendEvent(static_cast<FlValue*>(g_steal_pointer(&event)));

  g_dbus_method_invocation_return_value(invocation, nullptr);
}

// D-Bus property get handler
GVariant* OsMediaControlsPluginImpl::HandleGetProperty(
    GDBusConnection* connection,
    const gchar* sender,
    const gchar* object_path,
    const gchar* interface_name,
    const gchar* property_name,
    GError** error,
    gpointer user_data) {

  auto* self = static_cast<OsMediaControlsPluginImpl*>(user_data);
  if (!self) {
    g_set_error(error, G_DBUS_ERROR, G_DBUS_ERROR_FAILED,
                "Internal error: null user data");
    return nullptr;
  }

  if (!interface_name || !property_name) {
    g_set_error(error, G_DBUS_ERROR, G_DBUS_ERROR_INVALID_ARGS,
                "Invalid arguments");
    return nullptr;
  }

  if (g_strcmp0(interface_name, "org.mpris.MediaPlayer2") == 0) {
    if (g_strcmp0(property_name, "CanQuit") == 0) {
      return g_variant_new_boolean(self->can_quit_);
    } else if (g_strcmp0(property_name, "CanRaise") == 0) {
      return g_variant_new_boolean(self->can_raise_);
    } else if (g_strcmp0(property_name, "HasTrackList") == 0) {
      return g_variant_new_boolean(self->has_track_list_);
    } else if (g_strcmp0(property_name, "Identity") == 0) {
      return self->SafeVariantNewString(self->identity_);
    } else if (g_strcmp0(property_name, "SupportedUriSchemes") == 0) {
      GVariantBuilder builder;
      g_variant_builder_init(&builder, G_VARIANT_TYPE("as"));
      for (const auto& scheme : self->supported_uri_schemes_) {
        // Validate UTF-8 before adding
        if (!scheme.empty() && g_utf8_validate(scheme.c_str(), -1, nullptr)) {
          g_variant_builder_add(&builder, "s", scheme.c_str());
        }
      }
      return g_variant_builder_end(&builder);
    } else if (g_strcmp0(property_name, "SupportedMimeTypes") == 0) {
      GVariantBuilder builder;
      g_variant_builder_init(&builder, G_VARIANT_TYPE("as"));
      for (const auto& mime : self->supported_mime_types_) {
        // Validate UTF-8 before adding
        if (!mime.empty() && g_utf8_validate(mime.c_str(), -1, nullptr)) {
          g_variant_builder_add(&builder, "s", mime.c_str());
        }
      }
      return g_variant_builder_end(&builder);
    }
  } else if (g_strcmp0(interface_name, "org.mpris.MediaPlayer2.Player") == 0) {
    if (g_strcmp0(property_name, "PlaybackStatus") == 0) {
      return self->SafeVariantNewString(self->playback_status_);
    } else if (g_strcmp0(property_name, "Rate") == 0) {
      return g_variant_new_double(self->rate_);
    } else if (g_strcmp0(property_name, "Position") == 0) {
      return g_variant_new_int64(static_cast<gint64>(self->position_));
    } else if (g_strcmp0(property_name, "MinimumRate") == 0) {
      return g_variant_new_double(0.1);
    } else if (g_strcmp0(property_name, "MaximumRate") == 0) {
      return g_variant_new_double(10.0);
    } else if (g_strcmp0(property_name, "CanGoNext") == 0) {
      return g_variant_new_boolean(self->can_go_next_);
    } else if (g_strcmp0(property_name, "CanGoPrevious") == 0) {
      return g_variant_new_boolean(self->can_go_previous_);
    } else if (g_strcmp0(property_name, "CanPlay") == 0) {
      return g_variant_new_boolean(self->can_play_);
    } else if (g_strcmp0(property_name, "CanPause") == 0) {
      return g_variant_new_boolean(self->can_pause_);
    } else if (g_strcmp0(property_name, "CanSeek") == 0) {
      return g_variant_new_boolean(self->can_seek_);
    } else if (g_strcmp0(property_name, "CanControl") == 0) {
      return g_variant_new_boolean(TRUE);
    } else if (g_strcmp0(property_name, "Metadata") == 0) {
      GVariantBuilder builder;
      g_variant_builder_init(&builder, G_VARIANT_TYPE("a{sv}"));

      // Thread safety note: This function (HandleGetProperty) and SetMetadata must run
      // on the same thread. Currently both run on the GLib main loop thread, preventing
      // concurrent access to metadata_ map.

      auto title_it = self->metadata_.find("title");
      if (title_it != self->metadata_.end() && !title_it->second.empty()) {
        g_variant_builder_add(&builder, "{sv}", "xesam:title",
                             self->SafeVariantNewString(title_it->second));
      }

      auto artist_it = self->metadata_.find("artist");
      if (artist_it != self->metadata_.end() && !artist_it->second.empty()) {
        // Validate UTF-8 before adding to array
        if (g_utf8_validate(artist_it->second.c_str(), -1, nullptr)) {
          GVariantBuilder artist_builder;
          g_variant_builder_init(&artist_builder, G_VARIANT_TYPE("as"));
          g_variant_builder_add(&artist_builder, "s", artist_it->second.c_str());
          g_variant_builder_add(&builder, "{sv}", "xesam:artist",
                               g_variant_builder_end(&artist_builder));
        }
      }

      auto album_it = self->metadata_.find("album");
      if (album_it != self->metadata_.end() && !album_it->second.empty()) {
        g_variant_builder_add(&builder, "{sv}", "xesam:album",
                             self->SafeVariantNewString(album_it->second));
      }

      auto album_artist_it = self->metadata_.find("albumArtist");
      if (album_artist_it != self->metadata_.end() && !album_artist_it->second.empty()) {
        // Validate UTF-8 before adding to array
        if (g_utf8_validate(album_artist_it->second.c_str(), -1, nullptr)) {
          GVariantBuilder album_artist_builder;
          g_variant_builder_init(&album_artist_builder, G_VARIANT_TYPE("as"));
          g_variant_builder_add(&album_artist_builder, "s", album_artist_it->second.c_str());
          g_variant_builder_add(&builder, "{sv}", "xesam:albumArtist",
                               g_variant_builder_end(&album_artist_builder));
        }
      }

      auto duration_it = self->metadata_.find("duration");
      if (duration_it != self->metadata_.end() && !duration_it->second.empty()) {
        try {
          double duration = std::stod(duration_it->second);
          if (duration > 0 && std::isfinite(duration)) {
            g_variant_builder_add(&builder, "{sv}", "mpris:length",
                                 g_variant_new_int64(static_cast<gint64>(duration * 1000000)));
          }
        } catch (const std::invalid_argument& e) {
          g_warning("Failed to parse duration '%s': invalid argument",
                   duration_it->second.c_str());
        } catch (const std::out_of_range& e) {
          g_warning("Failed to parse duration '%s': out of range",
                   duration_it->second.c_str());
        }
      }

      if (!self->artwork_path_.empty()) {
        g_variant_builder_add(&builder, "{sv}", "mpris:artUrl",
                             self->SafeVariantNewString(self->artwork_path_));
      }

      g_variant_builder_add(&builder, "{sv}", "mpris:trackid",
                           g_variant_new_object_path("/org/mpris/MediaPlayer2/Track/current"));

      return g_variant_builder_end(&builder);
    } else if (g_strcmp0(property_name, "Volume") == 0) {
      return g_variant_new_double(1.0);
    }
  }

  g_set_error(error, G_DBUS_ERROR, G_DBUS_ERROR_UNKNOWN_PROPERTY,
              "Unknown property: %s", property_name);
  return nullptr;
}

// D-Bus property set handler
gboolean OsMediaControlsPluginImpl::HandleSetProperty(
    GDBusConnection* connection,
    const gchar* sender,
    const gchar* object_path,
    const gchar* interface_name,
    const gchar* property_name,
    GVariant* value,
    GError** error,
    gpointer user_data) {

  auto* self = static_cast<OsMediaControlsPluginImpl*>(user_data);
  if (!self) {
    g_set_error(error, G_DBUS_ERROR, G_DBUS_ERROR_FAILED,
                "Internal error: null user data");
    return FALSE;
  }

  if (!property_name || !value) {
    g_set_error(error, G_DBUS_ERROR, G_DBUS_ERROR_INVALID_ARGS,
                "Invalid arguments");
    return FALSE;
  }

  if (g_strcmp0(property_name, "Rate") == 0) {
    double rate = g_variant_get_double(value);
    self->rate_ = rate;

    // Send setSpeed event to Flutter
    g_autoptr(FlValue) event = fl_value_new_map();
    fl_value_set_string_take(event, "type", fl_value_new_string("setSpeed"));
    fl_value_set_string_take(event, "speed", fl_value_new_float(rate));

    self->SendEvent(static_cast<FlValue*>(g_steal_pointer(&event)));

    return TRUE;
  }

  g_set_error(error, G_DBUS_ERROR, G_DBUS_ERROR_UNKNOWN_PROPERTY,
              "Property not writable: %s", property_name);
  return FALSE;
}

// Emit PropertiesChanged signal
void OsMediaControlsPluginImpl::EmitPropertiesChanged(
    const char* interface_name,
    GVariantBuilder* changed_properties_builder) {

  if (!mpris_initialized_ || !connection_ || !changed_properties_builder) {
    if (changed_properties_builder) {
      // Clean up the builder if MPRIS is not initialized
      g_variant_builder_clear(changed_properties_builder);
    }
    return;
  }

  g_autoptr(GVariant) changed_properties =
      g_variant_ref_sink(g_variant_builder_end(changed_properties_builder));

  GVariantBuilder invalidated_builder;
  g_variant_builder_init(&invalidated_builder, G_VARIANT_TYPE("as"));
  g_autoptr(GVariant) invalidated =
      g_variant_ref_sink(g_variant_builder_end(&invalidated_builder));

  g_autoptr(GVariant) signal_params = g_variant_ref_sink(
      g_variant_new("(s@a{sv}@as)",
                    interface_name,
                    changed_properties,
                    invalidated));

  GError* error = nullptr;
  g_dbus_connection_emit_signal(
      connection_,
      nullptr,
      "/org/mpris/MediaPlayer2",
      "org.freedesktop.DBus.Properties",
      "PropertiesChanged",
      signal_params,
      &error);

  if (error) {
    g_warning("Failed to emit PropertiesChanged: %s", error->message);
    g_error_free(error);
  }
}

// Update MPRIS properties
void OsMediaControlsPluginImpl::UpdateMPRISProperties() {
  GVariantBuilder builder;
  g_variant_builder_init(&builder, G_VARIANT_TYPE("a{sv}"));

  g_variant_builder_add(&builder, "{sv}", "PlaybackStatus",
                       SafeVariantNewString(playback_status_));
  g_variant_builder_add(&builder, "{sv}", "Rate",
                       g_variant_new_double(rate_));
  g_variant_builder_add(&builder, "{sv}", "CanGoNext",
                       g_variant_new_boolean(can_go_next_));
  g_variant_builder_add(&builder, "{sv}", "CanGoPrevious",
                       g_variant_new_boolean(can_go_previous_));
  g_variant_builder_add(&builder, "{sv}", "CanPlay",
                       g_variant_new_boolean(can_play_));
  g_variant_builder_add(&builder, "{sv}", "CanPause",
                       g_variant_new_boolean(can_pause_));
  g_variant_builder_add(&builder, "{sv}", "CanSeek",
                       g_variant_new_boolean(can_seek_));

  EmitPropertiesChanged("org.mpris.MediaPlayer2.Player", &builder);
}

// Update metadata property
void OsMediaControlsPluginImpl::UpdateMetadataProperty() {
  if (!mpris_initialized_ || !connection_) {
    return;
  }

  GVariantBuilder builder;
  g_variant_builder_init(&builder, G_VARIANT_TYPE("a{sv}"));

  GVariant* metadata = HandleGetProperty(connection_, nullptr, nullptr,
                                          "org.mpris.MediaPlayer2.Player",
                                          "Metadata", nullptr, this);
  if (metadata) {
    g_variant_builder_add(&builder, "{sv}", "Metadata", metadata);
    EmitPropertiesChanged("org.mpris.MediaPlayer2.Player", &builder);
  } else {
    g_variant_builder_clear(&builder);
  }
}

// Handle method calls from Flutter
void OsMediaControlsPluginImpl::HandleMethodCall(FlMethodCall* method_call) {
  const gchar* method = fl_method_call_get_name(method_call);
  FlValue* args = fl_method_call_get_args(method_call);

  g_autoptr(FlMethodResponse) response = nullptr;

  if (strcmp(method, "setMetadata") == 0) {
    SetMetadata(args);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(fl_value_new_null()));
  } else if (strcmp(method, "setPlaybackState") == 0) {
    SetPlaybackState(args);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(fl_value_new_null()));
  } else if (strcmp(method, "enableControls") == 0) {
    EnableControls(args);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(fl_value_new_null()));
  } else if (strcmp(method, "disableControls") == 0) {
    DisableControls(args);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(fl_value_new_null()));
  } else if (strcmp(method, "setSkipIntervals") == 0) {
    SetSkipIntervals(args);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(fl_value_new_null()));
  } else if (strcmp(method, "setQueueInfo") == 0) {
    SetQueueInfo(args);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(fl_value_new_null()));
  } else if (strcmp(method, "clear") == 0) {
    Clear();
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(fl_value_new_null()));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }

  fl_method_call_respond(method_call, response, nullptr);
}

// Set metadata
// Thread safety note: This function modifies the metadata_ map and must run on the same
// thread as HandleGetProperty (which reads from metadata_). Both functions execute on
// the GLib main loop thread, ensuring single-threaded access and preventing race conditions.
void OsMediaControlsPluginImpl::SetMetadata(FlValue* args) {
  if (!args || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    return;
  }

  // Extract metadata fields
  std::string title = GetStringFromFlValue(args, "title");
  std::string artist = GetStringFromFlValue(args, "artist");
  std::string album = GetStringFromFlValue(args, "album");
  std::string album_artist = GetStringFromFlValue(args, "albumArtist");
  double duration = GetDoubleFromFlValue(args, "duration");

  // Update metadata map
  if (!title.empty()) metadata_["title"] = title;
  if (!artist.empty()) metadata_["artist"] = artist;
  if (!album.empty()) metadata_["album"] = album;
  if (!album_artist.empty()) metadata_["albumArtist"] = album_artist;
  if (duration > 0) metadata_["duration"] = std::to_string(duration);

  // Handle artwork - clean up old file first
  std::string old_artwork_path = artwork_path_;

  // Check for artwork URL first (preferred if provided)
  std::string artwork_url = GetStringFromFlValue(args, "artworkUrl");
  if (!artwork_url.empty()) {
    // Pass through URLs directly (file://, http://, https://)
    // Note: GNOME Shell only supports file:// reliably, but we'll pass through anyway
    if (artwork_url.find("file://") == 0 ||
        artwork_url.find("http://") == 0 ||
        artwork_url.find("https://") == 0) {
      artwork_path_ = artwork_url;
      artwork_data_.clear();  // Clear binary data if using URL
    } else {
      // If it's not a proper URL, try to make it a file:// URL
      if (artwork_url[0] == '/') {
        artwork_path_ = "file://" + artwork_url;
        artwork_data_.clear();
      }
    }
  } else {
    // Fall back to binary artwork data
    auto artwork = GetBytesFromFlValue(args, "artwork");
    if (!artwork.empty()) {
      // Save binary data to file with unique timestamp
      artwork_data_ = artwork;
      artwork_path_ = SaveArtworkToFile(artwork);
    }
  }

  // Clean up old artwork file if it's different and in our artwork directory
  if (old_artwork_path != artwork_path_) {
    CleanupArtworkFile(old_artwork_path);
  }

  UpdateMetadataProperty();
}

// Set playback state
void OsMediaControlsPluginImpl::SetPlaybackState(FlValue* args) {
  if (!args || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    return;
  }

  std::string state = GetStringFromFlValue(args, "state");
  double position = GetDoubleFromFlValue(args, "position");
  double speed = GetDoubleFromFlValue(args, "speed");

  // Map Flutter states to MPRIS PlaybackStatus
  if (state == "playing") {
    playback_status_ = "Playing";
  } else if (state == "paused") {
    playback_status_ = "Paused";
  } else if (state == "stopped" || state == "none") {
    playback_status_ = "Stopped";
  }

  // Update position (convert seconds to microseconds)
  position_ = position * 1000000;

  // Update rate
  if (speed > 0) {
    rate_ = speed;
  }

  UpdateMPRISProperties();
}

// Enable controls
void OsMediaControlsPluginImpl::EnableControls(FlValue* args) {
  if (!args || fl_value_get_type(args) != FL_VALUE_TYPE_LIST) {
    return;
  }

  size_t length = fl_value_get_length(args);
  for (size_t i = 0; i < length; i++) {
    FlValue* item = fl_value_get_list_value(args, i);
    if (!item) {
      g_warning("EnableControls: null item at index %zu", i);
      continue;
    }

    if (fl_value_get_type(item) == FL_VALUE_TYPE_STRING) {
      const char* control = fl_value_get_string(item);
      if (!control) {
        g_warning("EnableControls: null control string at index %zu", i);
        continue;
      }

      if (strcmp(control, "play") == 0) {
        can_play_ = true;
      } else if (strcmp(control, "pause") == 0) {
        can_pause_ = true;
      } else if (strcmp(control, "stop") == 0) {
        can_stop_ = true;
      } else if (strcmp(control, "next") == 0) {
        can_go_next_ = true;
      } else if (strcmp(control, "previous") == 0) {
        can_go_previous_ = true;
      } else if (strcmp(control, "seek") == 0) {
        can_seek_ = true;
      }
    }
  }

  UpdateMPRISProperties();
}

// Disable controls
void OsMediaControlsPluginImpl::DisableControls(FlValue* args) {
  if (!args || fl_value_get_type(args) != FL_VALUE_TYPE_LIST) {
    return;
  }

  size_t length = fl_value_get_length(args);
  for (size_t i = 0; i < length; i++) {
    FlValue* item = fl_value_get_list_value(args, i);
    if (!item) {
      g_warning("DisableControls: null item at index %zu", i);
      continue;
    }

    if (fl_value_get_type(item) == FL_VALUE_TYPE_STRING) {
      const char* control = fl_value_get_string(item);
      if (!control) {
        g_warning("DisableControls: null control string at index %zu", i);
        continue;
      }

      if (strcmp(control, "play") == 0) {
        can_play_ = false;
      } else if (strcmp(control, "pause") == 0) {
        can_pause_ = false;
      } else if (strcmp(control, "stop") == 0) {
        can_stop_ = false;
      } else if (strcmp(control, "next") == 0) {
        can_go_next_ = false;
      } else if (strcmp(control, "previous") == 0) {
        can_go_previous_ = false;
      } else if (strcmp(control, "seek") == 0) {
        can_seek_ = false;
      }
    }
  }

  UpdateMPRISProperties();
}

// Set skip intervals
void OsMediaControlsPluginImpl::SetSkipIntervals(FlValue* args) {
  if (!args || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    return;
  }

  skip_forward_interval_ = static_cast<int>(GetInt64FromFlValue(args, "forward"));
  skip_backward_interval_ = static_cast<int>(GetInt64FromFlValue(args, "backward"));

  // Note: MPRIS doesn't have standard skip interval support
  // This could be added as a custom extension if needed
}

// Set queue info
void OsMediaControlsPluginImpl::SetQueueInfo(FlValue* args) {
  // Note: MPRIS doesn't expose queue info in the basic Player interface
  // This would require implementing org.mpris.MediaPlayer2.TrackList
}

// Clear all media info
void OsMediaControlsPluginImpl::Clear() {
  metadata_.clear();
  artwork_data_.clear();

  // Clean up artwork file using helper function
  CleanupArtworkFile(artwork_path_);
  artwork_path_.clear();

  playback_status_ = "Stopped";
  position_ = 0;
  rate_ = 1.0;

  UpdateMPRISProperties();
  UpdateMetadataProperty();
}

// Start listening for events from Dart
void OsMediaControlsPluginImpl::StartListening() {
  is_listening_ = true;
}

// Stop listening for events from Dart
void OsMediaControlsPluginImpl::StopListening() {
  is_listening_ = false;
}

// Send event to Dart via event channel
void OsMediaControlsPluginImpl::SendEvent(FlValue* event) {
  if (!event) {
    return;
  }

  if (!is_listening_ || !event_channel_) {
    fl_value_unref(event);
    return;
  }

  g_autoptr(GError) error = nullptr;
  if (!fl_event_channel_send(event_channel_, event, nullptr, &error)) {
    g_warning("Failed to send event: %s", error->message);
  }

  fl_value_unref(event);
}

}  // namespace os_media_controls

// Method call handler
static void os_media_controls_plugin_handle_method_call(
    FlMethodChannel* channel,
    FlMethodCall* method_call,
    gpointer user_data) {
  OsMediaControlsPlugin* self = OS_MEDIA_CONTROLS_PLUGIN(user_data);
  if (self->impl) {
    self->impl->HandleMethodCall(method_call);
  }
}

// Event stream listen handler
static FlMethodErrorResponse* os_media_controls_plugin_listen(
    FlEventChannel* channel,
    FlValue* args,
    gpointer user_data) {
  OsMediaControlsPlugin* self = OS_MEDIA_CONTROLS_PLUGIN(user_data);

  if (self->impl) {
    self->impl->StartListening();
  }

  return nullptr;
}

// Event stream cancel handler
static FlMethodErrorResponse* os_media_controls_plugin_cancel(
    FlEventChannel* channel,
    FlValue* args,
    gpointer user_data) {
  OsMediaControlsPlugin* self = OS_MEDIA_CONTROLS_PLUGIN(user_data);

  if (self->impl) {
    self->impl->StopListening();
  }

  return nullptr;
}

static void os_media_controls_plugin_dispose(GObject* object) {
  OsMediaControlsPlugin* self = OS_MEDIA_CONTROLS_PLUGIN(object);

  if (self->impl) {
    delete self->impl;
    self->impl = nullptr;
  }

  if (self->method_channel) {
    g_object_unref(self->method_channel);
    self->method_channel = nullptr;
  }

  if (self->event_channel) {
    g_object_unref(self->event_channel);
    self->event_channel = nullptr;
  }

  G_OBJECT_CLASS(os_media_controls_plugin_parent_class)->dispose(object);
}

static void os_media_controls_plugin_class_init(OsMediaControlsPluginClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = os_media_controls_plugin_dispose;
}

static void os_media_controls_plugin_init(OsMediaControlsPlugin* self) {}

void os_media_controls_plugin_register_with_registrar(FlPluginRegistrar* registrar) {
  OsMediaControlsPlugin* plugin = OS_MEDIA_CONTROLS_PLUGIN(
      g_object_new(os_media_controls_plugin_get_type(), nullptr));

  plugin->registrar = registrar;

  // Create method channel
  g_autoptr(FlStandardMethodCodec) method_codec = fl_standard_method_codec_new();
  plugin->method_channel = fl_method_channel_new(
      fl_plugin_registrar_get_messenger(registrar),
      "com.edde746.os_media_controls/methods",
      FL_METHOD_CODEC(method_codec));
  fl_method_channel_set_method_call_handler(
      plugin->method_channel,
      os_media_controls_plugin_handle_method_call,
      g_object_ref(plugin),
      g_object_unref);

  // Create event channel
  g_autoptr(FlStandardMethodCodec) event_codec = fl_standard_method_codec_new();
  plugin->event_channel = fl_event_channel_new(
      fl_plugin_registrar_get_messenger(registrar),
      "com.edde746.os_media_controls/events",
      FL_METHOD_CODEC(event_codec));
  fl_event_channel_set_stream_handlers(
      plugin->event_channel,
      os_media_controls_plugin_listen,
      os_media_controls_plugin_cancel,
      g_object_ref(plugin),
      g_object_unref);

  // Create implementation
  plugin->impl = new os_media_controls::OsMediaControlsPluginImpl(
      registrar, plugin->event_channel);

  g_object_unref(plugin);
}
