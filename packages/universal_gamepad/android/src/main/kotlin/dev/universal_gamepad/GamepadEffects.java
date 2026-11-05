// SPDX-License-Identifier: MIT
package dev.universal_gamepad;

import android.hardware.Sensor;
import android.hardware.SensorEvent;
import android.hardware.SensorEventListener;
import android.hardware.SensorManager;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.os.VibrationEffect;
import android.os.Vibrator;
import android.view.InputDevice;
import java.util.HashMap;
import java.util.Map;

/** Optional PlezyNG feedback extension. Device IDs are the input plugin's IDs. */
public final class GamepadEffects {
  private String owner = "";
  private final Map<Integer, Device> devices = new HashMap<>();
  public boolean claim(String token) {
    if (token == null || !token.matches("[0-9a-f]{32}-[0-9]{1,10}-[0-9]{1,10}")) return false;
    if (!token.equals(owner)) { stop(); owner = token; }
    return true;
  }
  public void release(String token) { if (owner.equals(token)) stop(); }
  public void stop() {
    owner = "";
    for (Device device : devices.values()) device.close();
    devices.clear();
  }
  public void remove(int id) {
    Device device = devices.remove(id);
    if (device != null) device.close();
  }
  private Device device(String token, int id) {
    if (owner.isEmpty() || !owner.equals(token)) return null;
    InputDevice input = InputDevice.getDevice(id);
    if (input == null || ((input.getSources() & InputDevice.SOURCE_GAMEPAD) != InputDevice.SOURCE_GAMEPAD &&
        (input.getSources() & InputDevice.SOURCE_JOYSTICK) != InputDevice.SOURCE_JOYSTICK)) { remove(id); return null; }
    Device existing = devices.get(id);
    if (existing != null && !existing.descriptor.equals(input.getDescriptor())) { remove(id); existing = null; }
    if (existing == null && devices.size() < 4) {
      existing = new Device(input);
      devices.put(id, existing);
    }
    return existing;
  }
  public boolean apply(String token, int id, int flags, int low, int high, int duration, int left, int right, int triggerDuration, boolean sensors) {
    if (flags < 0 || flags > 7 || low < 0 || low > 65535 || high < 0 || high > 65535 ||
        left < 0 || left > 65535 || right < 0 || right > 65535 || duration < 0 || duration > 1000 ||
        triggerDuration < 0 || triggerDuration > 1000) return false;
    Device device = device(token, id);
    if (device == null) return false;
    try {
      if ((flags & 1) != 0 && device.vibrator != null && device.vibrator.hasVibrator()) {
        int magnitude = Math.max(low, high);
        if (magnitude == 0 || duration == 0) device.vibrator.cancel();
        else if (Build.VERSION.SDK_INT >= 26) device.vibrator.vibrate(VibrationEffect.createOneShot(duration, Math.max(1, magnitude * 255 / 65535)));
        else device.vibrator.vibrate(duration);
      }
      if ((flags & 4) != 0) device.sensors(sensors);
      return true;
    } catch (RuntimeException failure) { remove(id); return false; }
  }
  public double[] state(String token, int id) {
    Device device = device(token, id);
    if (device == null) return null;
    double[] result = new double[7];
    result[0] = device.capabilities;
    long now = SystemClock.elapsedRealtime();
    for (int i = 0; i < 6; i++) {
      if (device.enabled && device.updated[i / 3] > 0 && device.updated[i / 3] <= now && now - device.updated[i / 3] < 250) result[i + 1] = device.motion[i];
    }
    return result;
  }
  private static final class Device implements SensorEventListener {
    final String descriptor;
    final Vibrator vibrator;
    final SensorManager manager;
    final Sensor gyro, accel;
    final int capabilities;
    final double[] motion = new double[6];
    final long[] updated = new long[2];
    boolean enabled;
    Device(InputDevice input) {
      descriptor = input.getDescriptor();
      vibrator = Build.VERSION.SDK_INT >= 31 ? input.getVibratorManager().getDefaultVibrator() : input.getVibrator();
      manager = Build.VERSION.SDK_INT >= 31 ? input.getSensorManager() : null;
      gyro = manager == null ? null : manager.getDefaultSensor(Sensor.TYPE_GYROSCOPE);
      accel = manager == null ? null : manager.getDefaultSensor(Sensor.TYPE_ACCELEROMETER);
      // Android exposes a combined vibrator, not a guaranteed mapping of
      // motor IDs to left/right or trigger actuators. Never invent one.
      capabilities = (vibrator != null && vibrator.hasVibrator() ? 1 : 0) | (gyro != null ? 4 : 0) | (accel != null ? 8 : 0);
    }
    void sensors(boolean value) {
      if (value == enabled || manager == null) return;
      manager.unregisterListener(this);
      enabled = false;
      java.util.Arrays.fill(motion, 0);
      java.util.Arrays.fill(updated, 0);
      if (value) {
        Handler main = new Handler(Looper.getMainLooper());
        boolean g = gyro != null && manager.registerListener(this, gyro, 20000, main);
        boolean a = accel != null && manager.registerListener(this, accel, 20000, main);
        enabled = g || a;
      }
    }
    void close() {
      sensors(false);
      if (vibrator != null) { try { vibrator.cancel(); } catch (RuntimeException ignored) { } }
    }
    @Override public void onAccuracyChanged(Sensor sensor, int accuracy) { }
    @Override public void onSensorChanged(SensorEvent event) {
      if (!enabled || event.values.length < 3) return;
      int offset = event.sensor == gyro ? 0 : event.sensor == accel ? 3 : -1;
      if (offset < 0) return;
      for (int i = 0; i < 3; i++) if (!Float.isFinite(event.values[i])) return;
      for (int i = 0; i < 3; i++) motion[offset + i] = event.values[i];
      updated[offset / 3] = event.timestamp / 1000000;
    }
  }
}
