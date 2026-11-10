// SPDX-License-Identifier: AGPL-3.0-only
#pragma once
#include <flutter/flutter_engine.h>

#include <memory>
class WorkspaceViews {
 public:
  explicit WorkspaceViews(flutter::FlutterEngine* engine);
  ~WorkspaceViews();
  WorkspaceViews(const WorkspaceViews&) = delete;
  WorkspaceViews& operator=(const WorkspaceViews&) = delete;

 private:
  class Impl;
  std::unique_ptr<Impl> impl_;
};
