// SPDX-License-Identifier: AGPL-3.0-only
#pragma once
#import <Foundation/Foundation.h>
#include <fcntl.h>
#include <unistd.h>
#include <mutex>
#include <stdexcept>

// One small durable record precedes native GPU submission. A process exit can
// leave it armed; the next process then blocks automatic loading of that path.
// Explicit selection/reload can retry. Owner tokens prevent an old host's close
// from clearing a newer host's record. The journal is independent of Dart's
// preference write queue and remains usable during native lifecycle callbacks.
class AppleVisualizerRecovery {
  std::mutex mutex_;
  NSURL* file_;
  NSMutableDictionary<NSString*, NSString*>* blocked_;
  NSDictionary<NSString*, NSString*>* active_ = nil;
  bool unreadable_ = false;

  static bool Text(id value, NSUInteger maximum = 32768) {
    return [value isKindOfClass:[NSString class]] && [value length] > 0 &&
        [value lengthOfBytesUsingEncoding:NSUTF8StringEncoding] <= maximum;
  }
  void Remember(NSString* path, NSString* reason) {
    if (!Text(path)) return;
    // Keep the most recent failure even when the bounded history is full.
    if (!blocked_[path] && blocked_.count >= 32) {
      NSString* evicted = [[blocked_.allKeys sortedArrayUsingSelector:@selector(compare:)] firstObject];
      [blocked_ removeObjectForKey:evicted];
    }
    blocked_[path] = Text(reason, 8192) ? reason : @"The previous visualization session ended unexpectedly.";
  }
  void Save() {
    NSError* error = nil;
    NSDictionary* value = @{@"schemaVersion":@1, @"blocked":blocked_, @"active":active_ ?: (id)[NSNull null]};
    NSData* bytes = [NSJSONSerialization dataWithJSONObject:value options:0 error:&error];
    if (!bytes || bytes.length > 2 * 1024 * 1024 ||
        ![bytes writeToURL:file_ options:NSDataWritingAtomic error:&error])
      throw std::runtime_error("Could not save visualization recovery state.");
    // NSData's atomic replacement alone does not promise durable file content.
    int fd = open(file_.fileSystemRepresentation, O_RDWR | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) throw std::runtime_error("Could not retain visualization recovery state.");
    const int result = fsync(fd);
    close(fd);
    if (result != 0) throw std::runtime_error("Could not flush visualization recovery state.");
    unreadable_ = false;
  }
 public:
  explicit AppleVisualizerRecovery(NSURL* file) : file_(file), blocked_([NSMutableDictionary dictionary]) {
    NSError* error = nil;
    auto* manager = NSFileManager.defaultManager;
    if (![manager createDirectoryAtURL:file.URLByDeletingLastPathComponent withIntermediateDirectories:YES
        attributes:@{NSFilePosixPermissions:@0700} error:&error])
      throw std::runtime_error("Could not open visualization recovery storage.");
    NSDictionary* attributes = [manager attributesOfItemAtPath:file.path error:&error];
    if (!attributes) {
      if (error && error.code != NSFileReadNoSuchFileError && error.code != NSFileNoSuchFileError) unreadable_ = true;
      return;
    }
    if (![attributes[NSFileType] isEqual:NSFileTypeRegular] || [attributes[NSFileSize] unsignedLongLongValue] > 2 * 1024 * 1024) {
      unreadable_ = true; return;
    }
    NSData* data = [NSData dataWithContentsOfURL:file options:0 error:&error];
    id value = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&error] : nil;
    if (![value isKindOfClass:[NSDictionary class]] || ![value[@"schemaVersion"] isEqual:@1] ||
        ![value[@"blocked"] isKindOfClass:[NSDictionary class]] || [value[@"blocked"] count] > 32) {
      unreadable_ = true; return;
    }
    for (id path in value[@"blocked"]) {
      id reason = value[@"blocked"][path];
      if (!Text(path) || !Text(reason, 8192)) { unreadable_ = true; return; }
      blocked_[path] = reason;
    }
    id active = value[@"active"];
    if (active != [NSNull null]) {
      if (![active isKindOfClass:[NSDictionary class]] || !Text(active[@"path"]) || !Text(active[@"owner"], 256)) {
        unreadable_ = true; return;
      }
      Remember(active[@"path"], @"The previous visualization session ended unexpectedly.");
    }
    // An old process's active owner can never acknowledge this process's work.
    active_ = nil;
  }
  static AppleVisualizerRecovery& Shared() {
    static auto* journal = [] {
      NSURL* root = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
      if (!root) throw std::runtime_error("Visualization recovery storage is unavailable.");
      return new AppleVisualizerRecovery([[root URLByAppendingPathComponent:@"visualizer" isDirectory:YES]
          URLByAppendingPathComponent:@"apple-render-recovery.json"]);
    }();
    return *journal;
  }
  bool AutomaticAllowed(NSString* path) {
    std::lock_guard<std::mutex> lock(mutex_);
    return Text(path) && !unreadable_ && blocked_[path] == nil;
  }
  void Begin(NSString* owner, NSString* path) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!Text(owner, 256) || !Text(path)) throw std::runtime_error("Invalid visualization recovery identity.");
    if ([active_[@"owner"] isEqual:owner] && [active_[@"path"] isEqual:path]) return;
    NSDictionary* previous = active_;
    if (previous) Remember(previous[@"path"], @"The previous visualization session did not finish.");
    active_ = @{@"owner":owner, @"path":path};
    try { Save(); } catch (...) { active_ = previous; unreadable_ = true; throw; }
  }
  void End(NSString* owner, bool healthy, NSString* reason = nil, bool rendered = true) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (![active_[@"owner"] isEqual:owner]) return;
    if (healthy && rendered) [blocked_ removeObjectForKey:active_[@"path"]];
    if (!healthy) Remember(active_[@"path"], reason);
    active_ = nil;
    try { Save(); } catch (...) { unreadable_ = true; throw; }
  }
};
