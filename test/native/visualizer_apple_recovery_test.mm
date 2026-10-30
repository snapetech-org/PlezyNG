// SPDX-License-Identifier: AGPL-3.0-only
#include "../../shared/apple/MpvPlayer/VisualizerRecovery.h"
#include <iostream>
namespace {
void Require(bool value) { if (!value) throw std::runtime_error("Apple visualization recovery regression failed."); }
struct TemporaryDirectory {
  NSURL* root;
  TemporaryDirectory() : root([NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES]) {}
  ~TemporaryDirectory() { [NSFileManager.defaultManager removeItemAtURL:root error:nullptr]; }
};
}
int main() {
  @autoreleasepool {
    try {
      TemporaryDirectory directory;
      NSURL* file = [directory.root URLByAppendingPathComponent:@"recovery.json"];
      {
        AppleVisualizerRecovery first(file);
        Require(first.AutomaticAllowed(@"/preset.milk"));
        first.Begin(@"first-process", @"/preset.milk"); // Simulated process exit without an acknowledgement.
      }
      {
        AppleVisualizerRecovery next(file);
        Require(!next.AutomaticAllowed(@"/preset.milk"));
        Require(next.AutomaticAllowed(@"/other.milk"));
        next.Begin(@"retry", @"/preset.milk");
        next.End(@"first-process", true); // A stale owner cannot clear a retry.
        AppleVisualizerRecovery whileArmed(file);
        Require(!whileArmed.AutomaticAllowed(@"/preset.milk"));
        next.End(@"retry", true, nil, false); // No submitted frame: keep the earlier failure.
      }
      {
        AppleVisualizerRecovery next(file);
        Require(!next.AutomaticAllowed(@"/preset.milk"));
        next.Begin(@"manual", @"/preset.milk");
        next.End(@"manual", true);
      }
      {
        AppleVisualizerRecovery next(file);
        Require(next.AutomaticAllowed(@"/preset.milk"));
        next.Begin(@"failing", @"/preset.milk");
        next.End(@"failing", false, @"Drain timed out.");
        next.Begin(@"old", @"/old.milk");
        next.Begin(@"new", @"/new.milk"); // Displaced unfinished work stays blocked.
        next.End(@"old", true);
        next.End(@"new", true);
      }
      {
        AppleVisualizerRecovery next(file);
        Require(!next.AutomaticAllowed(@"/preset.milk"));
        Require(!next.AutomaticAllowed(@"/old.milk"));
        Require(next.AutomaticAllowed(@"/new.milk"));
        for (int index = 0; index < 40; ++index) {
          NSString* path = [NSString stringWithFormat:@"/failure-%d.milk", index];
          next.Begin(@"bounded", path);
          next.End(@"bounded", false, [@"x" stringByPaddingToLength:9000 withString:@"x" startingAtIndex:0]);
        }
      }
      {
        AppleVisualizerRecovery next(file);
        Require(!next.AutomaticAllowed(@"/failure-39.milk"));
        Require(next.AutomaticAllowed(@"/unrelated.milk")); // History and reason text stayed readable/bounded.
      }
      Require([[@"corrupt" dataUsingEncoding:NSUTF8StringEncoding] writeToURL:file atomically:YES]);
      {
        AppleVisualizerRecovery next(file);
        Require(!next.AutomaticAllowed(@"/any.milk"));
        next.Begin(@"explicit", @"/any.milk"); // Explicit retry replaces a malformed journal.
        next.End(@"explicit", true);
      }
      {
        AppleVisualizerRecovery next(file);
        Require(next.AutomaticAllowed(@"/any.milk"));
      }
      std::cout << "Apple visualization recovery regressions passed\n";
    } catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
  }
}
