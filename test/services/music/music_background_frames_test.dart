import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/music/music_background_frames.dart';

void main() {
  testWidgets('headless dirty builds coalesce and foreground frames keep normal scheduling', (tester) async {
    final binding = tester.binding;
    var frames = 0;
    final original = binding.buildOwner!.onBuildScheduled;
    final controller = MusicBackgroundFrames(binding, warmUp: () => frames++);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    controller.install();
    controller.install();
    binding.buildOwner!.onBuildScheduled!();
    binding.buildOwner!.onBuildScheduled!();
    await tester.idle();
    expect(frames, 1);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    binding.buildOwner!.onBuildScheduled!();
    await tester.idle();
    expect(frames, 1);
    controller.dispose();
    expect(binding.buildOwner!.onBuildScheduled, same(original));
  });
  testWidgets('teardown cancels a scheduled background build', (tester) async {
    final binding = tester.binding;
    var frames = 0;
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    final controller = MusicBackgroundFrames(binding, warmUp: () => frames++)..install();
    binding.buildOwner!.onBuildScheduled!();
    controller.dispose();
    await tester.idle();
    expect(frames, 0);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });
  testWidgets('warm phone engines enable background frames only while attached to a car', (tester) async {
    final binding = tester.binding;
    var frames = 0, connected = false;
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    final controller = MusicBackgroundFrames(binding, warmUp: () => frames++, active: () => connected)..install();
    binding.buildOwner!.onBuildScheduled!();
    await tester.idle();
    expect(frames, 0);
    connected = true;
    binding.buildOwner!.onBuildScheduled!();
    await tester.idle();
    expect(frames, 1);
    connected = false;
    binding.buildOwner!.onBuildScheduled!();
    await tester.idle();
    expect(frames, 1);
    controller.dispose();
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });
  testWidgets('attaching a car wakes a build already dirtied while the phone was paused', (tester) async {
    final binding = tester.binding;
    var frames = 0;
    MusicBackgroundFrames.carConnected = false;
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    final controller = MusicBackgroundFrames(
      binding,
      warmUp: () => frames++,
      active: () => MusicBackgroundFrames.carConnected,
    )..install();
    binding.buildOwner!.onBuildScheduled!();
    await tester.idle();
    expect(frames, 0);
    MusicBackgroundFrames.carConnected = true;
    await tester.idle();
    expect(frames, 1);
    MusicBackgroundFrames.carConnected = false;
    controller.dispose();
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });
}
