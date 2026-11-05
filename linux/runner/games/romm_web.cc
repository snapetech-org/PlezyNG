#include "romm_web.h"
#include <webkit2/webkit2.h>
#include <cmath>
#include <string>

namespace {
struct Surface { GtkOverlay* overlay; GtkWidget* fixed=nullptr; WebKitWebView* web=nullptr; std::string origin,owner; FlMethodChannel* channel=nullptr; };
void respond(FlMethodCall* call,FlValue* value=nullptr) {
  g_autoptr(FlMethodResponse) response=FL_METHOD_RESPONSE(fl_method_success_response_new(value));
  fl_method_call_respond(call,response,nullptr);
}
void fail(FlMethodCall* call) {
  g_autoptr(FlMethodResponse) response=FL_METHOD_RESPONSE(fl_method_error_response_new("unavailable","Embedded player unavailable",nullptr));
  fl_method_call_respond(call,response,nullptr);
}
const char* text(FlValue* args,const char* key) {
  auto* value=args&&fl_value_get_type(args)==FL_VALUE_TYPE_MAP?fl_value_lookup_string(args,key):nullptr;
  return value&&fl_value_get_type(value)==FL_VALUE_TYPE_STRING?fl_value_get_string(value):"";
}
double number(FlValue* args,const char* key) {
  auto* value=args&&fl_value_get_type(args)==FL_VALUE_TYPE_MAP?fl_value_lookup_string(args,key):nullptr;
  if(!value)return 0;
  if(fl_value_get_type(value)==FL_VALUE_TYPE_FLOAT)return fl_value_get_float(value);
  if(fl_value_get_type(value)==FL_VALUE_TYPE_INT)return static_cast<double>(fl_value_get_int(value));
  return 0;
}
void close(Surface* surface) {
  // Destroying a page can itself emit cancellation signals. Disconnect first
  // so retirement cannot report a failure against its replacement.
  if(surface->web)g_signal_handlers_disconnect_by_data(surface->web,surface);
  if(surface->fixed)gtk_widget_destroy(surface->fixed);
  surface->fixed=nullptr;surface->web=nullptr;surface->origin.clear();surface->owner.clear();
}
void loadError(Surface* surface,WebKitWebView* web) {
  if(surface->web!=web || surface->owner.empty() || !surface->channel)return;
  g_autoptr(FlValue) owner=fl_value_new_string(surface->owner.c_str());
  fl_method_channel_invoke_method(surface->channel,"loadError",owner,nullptr,nullptr,nullptr);
}
bool permitted(Surface* surface,const char* url) {
  const std::string value=url?url:"";
  return value.rfind(surface->origin+"/",0)==0 || value==surface->origin;
}
gboolean policy(WebKitWebView* web,WebKitPolicyDecision* decision,WebKitPolicyDecisionType type,gpointer user) {
  auto* surface=static_cast<Surface*>(user);
  if(type==WEBKIT_POLICY_DECISION_TYPE_NEW_WINDOW_ACTION){webkit_policy_decision_ignore(decision);return TRUE;}
  if(type==WEBKIT_POLICY_DECISION_TYPE_NAVIGATION_ACTION) {
    auto* nav=WEBKIT_NAVIGATION_POLICY_DECISION(decision);
    auto* action=webkit_navigation_policy_decision_get_navigation_action(nav);
    const char* uri=webkit_uri_request_get_uri(webkit_navigation_action_get_request(action));
    if(!permitted(surface,uri)){webkit_policy_decision_ignore(decision);return TRUE;}
  }
  if(type==WEBKIT_POLICY_DECISION_TYPE_RESPONSE) {
    auto* response=WEBKIT_RESPONSE_POLICY_DECISION(decision);
    if(webkit_response_policy_decision_is_main_frame_main_resource(response) &&
       webkit_uri_response_get_status_code(webkit_response_policy_decision_get_response(response))>=400)loadError(surface,web);
  }
  return FALSE;
}
void layout(Surface* surface,FlValue* args) {
  const double x=number(args,"x"),y=number(args,"y"),w=number(args,"width"),h=number(args,"height");
  if(!std::isfinite(x)||!std::isfinite(y)||!std::isfinite(w)||!std::isfinite(h)||w<1||h<1||w>16384||h>16384)return;
  gtk_fixed_move(GTK_FIXED(surface->fixed),GTK_WIDGET(surface->web),static_cast<int>(x),static_cast<int>(y));
  gtk_widget_set_size_request(GTK_WIDGET(surface->web),static_cast<int>(w),static_cast<int>(h));
}
void method(FlMethodChannel*,FlMethodCall* call,gpointer data) {
  auto* surface=static_cast<Surface*>(data);const char* name=fl_method_call_get_name(call);auto* args=fl_method_call_get_args(call);
  if(g_strcmp0(name,"available")==0){g_autoptr(FlValue) yes=fl_value_new_bool(TRUE);respond(call,yes);return;}
  const std::string owner=text(args,"owner");
  if(owner.empty() || owner.size()>128){fail(call);return;}
  if(g_strcmp0(name,"open")!=0 && owner!=surface->owner){
    if(g_strcmp0(name,"close")==0 || g_strcmp0(name,"visible")==0){respond(call);return;}
    fail(call);return;
  }
  if(g_strcmp0(name,"close")==0){close(surface);respond(call);return;}
  if(g_strcmp0(name,"visible")==0){if(surface->fixed)gtk_widget_set_visible(surface->fixed,number(args,"value")!=0);respond(call);return;}
  if(g_strcmp0(name,"open")==0){
    const std::string origin=text(args,"origin"),url=text(args,"url");
    if(origin.rfind("http://127.0.0.1:",0)!=0 || origin.find('/',7)!=std::string::npos || url.rfind(origin+"/",0)!=0){fail(call);return;}
    close(surface);surface->origin=origin;surface->owner=owner;
    surface->fixed=gtk_fixed_new();gtk_overlay_add_overlay(surface->overlay,surface->fixed);
    gtk_overlay_set_overlay_pass_through(surface->overlay,surface->fixed,FALSE);
    const std::string partition=text(args,"partition");
    if(partition.size()!=64 || partition.find_first_not_of("0123456789abcdef")!=std::string::npos){close(surface);fail(call);return;}
    gchar* directory=g_build_filename(g_get_user_data_dir(),"plezyng","romm-web",partition.c_str(),nullptr);
    auto* manager=webkit_website_data_manager_new("base-data-directory",directory,"base-cache-directory",directory,nullptr);
    g_free(directory);
    auto* context=webkit_web_context_new_with_website_data_manager(manager);g_object_unref(manager);
    surface->web=WEBKIT_WEB_VIEW(webkit_web_view_new_with_context(context));g_object_unref(context);
    auto* settings=webkit_web_view_get_settings(surface->web);
    webkit_settings_set_enable_javascript(settings,TRUE);
    webkit_settings_set_enable_developer_extras(settings,FALSE);
    webkit_settings_set_media_playback_requires_user_gesture(settings,FALSE);
    webkit_settings_set_allow_file_access_from_file_urls(settings,FALSE);
    webkit_settings_set_allow_universal_access_from_file_urls(settings,FALSE);
    g_signal_connect(surface->web,"decide-policy",G_CALLBACK(policy),surface);
    g_signal_connect(surface->web,"load-failed",G_CALLBACK(+[](WebKitWebView* web,WebKitLoadEvent,const gchar*,GError* error,gpointer user)->gboolean{
      if(!g_error_matches(error,WEBKIT_NETWORK_ERROR,WEBKIT_NETWORK_ERROR_CANCELLED))loadError(static_cast<Surface*>(user),web);
      return FALSE;
    }),surface);
    g_signal_connect(surface->web,"web-process-terminated",G_CALLBACK(+[](WebKitWebView* web,WebKitWebProcessTerminationReason,gpointer user){
      loadError(static_cast<Surface*>(user),web);
    }),surface);
    g_signal_connect(surface->web,"permission-request",G_CALLBACK(+[](WebKitWebView*,WebKitPermissionRequest* request,gpointer)->gboolean{
      webkit_permission_request_deny(request);return TRUE;
    }),nullptr);
    gtk_fixed_put(GTK_FIXED(surface->fixed),GTK_WIDGET(surface->web),0,0);layout(surface,args);
    gtk_widget_show_all(surface->fixed);
    gtk_widget_set_visible(surface->fixed,number(args,"visible")!=0);
    if(number(args,"visible")!=0)gtk_widget_grab_focus(GTK_WIDGET(surface->web));
    webkit_web_view_load_uri(surface->web,url.c_str());respond(call);return;
  }
  if(!surface->web){fail(call);return;}
  if(g_strcmp0(name,"resize")==0){layout(surface,args);respond(call);return;}
  if(g_strcmp0(name,"evaluate")==0){
    g_object_ref(call);
    webkit_web_view_evaluate_javascript(surface->web,text(args,"script"),-1,nullptr,nullptr,nullptr,
      +[](GObject* object,GAsyncResult* result,gpointer value){
        auto* call=FL_METHOD_CALL(value);GError* error=nullptr;
        auto* js=webkit_web_view_evaluate_javascript_finish(WEBKIT_WEB_VIEW(object),result,&error);
        if(error){g_error_free(error);fail(call);}else{
          gchar* string=js&&!jsc_value_is_null(js)&&!jsc_value_is_undefined(js)?jsc_value_to_string(js):nullptr;
          g_autoptr(FlValue) output=string?fl_value_new_string(string):fl_value_new_null();respond(call,output);
          g_free(string);if(js)g_object_unref(js);
        }
        g_object_unref(call);
      },call);return;
  }
  fl_method_call_respond_not_implemented(call,nullptr);
}
}
void romm_web_register(FlPluginRegistrar* registrar,GtkOverlay* overlay) {
  auto* surface=new Surface{overlay,nullptr,nullptr,{}, {}};
  g_autoptr(FlStandardMethodCodec) codec=fl_standard_method_codec_new();
  g_autoptr(FlMethodChannel) channel=fl_method_channel_new(fl_plugin_registrar_get_messenger(registrar),"com.plezy/romm_web",FL_METHOD_CODEC(codec));
  surface->channel=channel; // The channel's handler owns Surface; avoid a ref cycle.
  fl_method_channel_set_method_call_handler(channel,method,surface,[](gpointer value){auto* s=static_cast<Surface*>(value);close(s);delete s;});
}
