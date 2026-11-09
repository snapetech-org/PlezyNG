// Copyright (c) 2026 LG Electronics, Inc. All rights reserved.
// Copyright 2021 Sony Corporation. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include <flutter/basic_message_channel.h>
#include <flutter/encodable_value.h>
#include <flutter/standard_message_codec.h>
#include <flutter_window.h>

#include "flutter/generated_plugin_registrant.h"

class App : public FlutterWindow {
 public:
  bool OnCreate() override {
    if (!FlutterWindow::OnCreate()) return false;
    RegisterPlugins(GetRegistrar());
    return true;
  }

 protected:
  std::unique_ptr<flutter::FlutterViewController> CreateController(
      const flutter::FlutterViewController::ViewProperties& properties, const flutter::DartProject& project,
      const std::vector<std::string>& engine_switches) override {
    auto controller = FlutterWindow::CreateController(properties, project, engine_switches);
    if (!controller || !controller->view()) return controller;
    auto* view = controller->view();
    // Claim Back before Dart starts. Otherwise webOS displays its exit prompt
    // without delivering the key to the player's menus or route stack.
    view->SetWindowProperty("_WEBOS_ACCESS_POLICY_KEYS_BACK", "true");
    navigation_channel_ = std::make_unique<flutter::BasicMessageChannel<flutter::EncodableValue>>(
        controller->engine()->messenger(), "com.plezy/webos_system_navigation",
        &flutter::StandardMessageCodec::GetInstance());
    navigation_channel_->SetMessageHandler(
        [view](const flutter::EncodableValue& message, const flutter::MessageReply<flutter::EncodableValue>& reply) {
          const auto* values = std::get_if<flutter::EncodableMap>(&message);
          if (values) {
            const auto it = values->find(flutter::EncodableValue("backPassthroughEnabled"));
            if (it != values->end()) {
              if (const auto* passthrough = std::get_if<bool>(&it->second)) {
                view->SetWindowProperty("_WEBOS_ACCESS_POLICY_KEYS_BACK", *passthrough ? "false" : "true");
                reply(flutter::EncodableValue(true));
                return;
              }
            }
          }
          reply(flutter::EncodableValue(false));
        });
    return controller;
  }

 private:
  std::unique_ptr<flutter::BasicMessageChannel<flutter::EncodableValue>> navigation_channel_;
};

int main(int argc, char** argv) {
  App app;
  return app.Run(argc, argv);
}
