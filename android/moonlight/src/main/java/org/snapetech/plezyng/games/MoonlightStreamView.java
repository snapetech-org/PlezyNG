// SPDX-License-Identifier: GPL-3.0-or-later
package org.snapetech.plezyng.games;

import android.app.Activity;
import android.content.Context;
import android.graphics.Color;
import android.hardware.input.InputManager;
import android.net.ConnectivityManager;
import android.net.wifi.WifiManager;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import android.view.Display;
import android.view.Gravity;
import android.view.InputDevice;
import android.view.KeyEvent;
import android.view.MotionEvent;
import android.view.Surface;
import android.view.SurfaceHolder;
import android.view.View;
import android.view.inputmethod.InputMethodManager;
import android.widget.FrameLayout;
import android.widget.TextView;
import com.limelight.binding.PlatformBinding;
import com.limelight.binding.audio.AndroidAudioRenderer;
import com.limelight.binding.input.ControllerHandler;
import com.limelight.binding.input.KeyboardTranslator;
import com.limelight.binding.input.touch.AbsoluteTouchContext;
import com.limelight.binding.input.touch.RelativeTouchContext;
import com.limelight.binding.input.touch.TouchContext;
import com.limelight.binding.input.virtual_controller.VirtualController;
import com.limelight.binding.video.CrashListener;
import com.limelight.binding.video.MediaCodecDecoderRenderer;
import com.limelight.binding.video.MediaCodecHelper;
import com.limelight.binding.video.PerfOverlayListener;
import com.limelight.nvstream.NvConnection;
import com.limelight.nvstream.NvConnectionListener;
import com.limelight.nvstream.StreamConfiguration;
import com.limelight.nvstream.http.ComputerDetails;
import com.limelight.nvstream.http.NvApp;
import com.limelight.nvstream.input.KeyboardPacket;
import com.limelight.nvstream.input.MouseButtonPacket;
import com.limelight.nvstream.jni.MoonBridge;
import com.limelight.preferences.GlPreferences;
import com.limelight.preferences.PreferenceConfiguration;
import com.limelight.ui.GameGestures;
import com.limelight.ui.StreamView;
import java.security.cert.CertificateFactory;
import java.security.cert.X509Certificate;
import java.io.ByteArrayInputStream;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;

/** Moonlight transport hosted by Pleazyng's retained Android workspace surface. */
public final class MoonlightStreamView extends FrameLayout
    implements SurfaceHolder.Callback, NvConnectionListener, GameGestures,
               StreamView.InputCallbacks, PerfOverlayListener {
  private static final String TAG = "PleazyMoonlight";
  private final Activity activity;
  private final Handler main = new Handler(Looper.getMainLooper());
  private final Object wifiLockGuard = new Object();
  private final StreamView streamView;
  private final TextView status;
  private final AtomicBoolean connectionStarted = new AtomicBoolean();
  private final AtomicBoolean stopStarted = new AtomicBoolean();
  private final AtomicBoolean decoderStopping = new AtomicBoolean();
  private final CountDownLatch stopped = new CountDownLatch(1);
  private final Map<Integer, Short> heldKeys = new HashMap<>();
  private final TouchContext[] touchContexts = new TouchContext[2];
  private int lastMouseButtonState;
  private InputManager inputManager;
  private KeyboardTranslator keyboardTranslator;
  private PreferenceConfiguration preferences;
  private NvConnection connection;
  private MediaCodecDecoderRenderer decoder;
  private AndroidAudioRenderer audio;
  private ControllerHandler controller;
  private VirtualController virtualController;
  private WifiManager.WifiLock highPerfWifiLock;
  private WifiManager.WifiLock lowLatencyWifiLock;
  private volatile String sessionState = "connecting";
  private volatile boolean inputEnabled;
  private volatile boolean inputLeaseGranted;
  private volatile boolean closed;
  private volatile boolean audioEnabled;
  private volatile Runnable onStateChanged;
  private volatile String errorLabel = "The stream could not start.";
  private Map<String, Object> labels = java.util.Collections.emptyMap();

  public MoonlightStreamView(Context context, Map<?, ?> rawArguments) {
    super(context);
    if (!(context instanceof Activity)) {
      throw new IllegalArgumentException("Moonlight workspace requires an Activity context");
    }
    activity = (Activity) context;
    setBackgroundColor(Color.BLACK);
    setFocusable(true);
    setFocusableInTouchMode(true);
    streamView = new StreamView(context);
    streamView.setBackgroundColor(Color.BLACK);
    streamView.setFocusable(true);
    streamView.setFocusableInTouchMode(true);
    streamView.setOnKeyListener((view, keyCode, event) ->
        event.getAction() == KeyEvent.ACTION_DOWN ? dispatchKeyDown(event) :
        event.getAction() == KeyEvent.ACTION_UP && dispatchKeyUp(event));
    streamView.setOnGenericMotionListener((view, event) -> handleMotionEvent(event));
    streamView.setInputCallbacks(this);
    streamView.getHolder().addCallback(this);
    addView(streamView, new FrameLayout.LayoutParams(-1, -1, Gravity.CENTER));
    status = new TextView(context);
    status.setTextColor(Color.WHITE);
    status.setTextSize(16);
    status.setGravity(Gravity.CENTER);
    status.setBackgroundColor(0x99000000);
    status.setPadding(dp(20), dp(12), dp(20), dp(12));
    addView(status, new FrameLayout.LayoutParams(-1, -1, Gravity.CENTER));

    Map<String, Object> args;
    try {
      args = EmbeddedGameStream.workspaceArguments(context, rawArguments);
      labels = args;
      audioEnabled = Boolean.TRUE.equals(args.get("audioEnabled"));
      errorLabel = (String) args.get("failedLabel");
      preferences = PreferenceConfiguration.readPreferences(context);
      preferences.onscreenController = Boolean.TRUE.equals(args.get("touchControls"));
      if (preferences.stretchVideo) {
        streamView.getHolder().setFixedSize(preferences.width, preferences.height);
      } else {
        streamView.setDesiredAspectRatio((double) preferences.width / preferences.height);
      }
      GlPreferences glPreferences = GlPreferences.readPreferences(context);
      MediaCodecHelper.initialize(context, glPreferences.glRenderer);

      boolean hdr = canPresentHdr() && preferences.enableHdr && Boolean.TRUE.equals(args.get("hdr"));
      ConnectivityManager connectivity =
          (ConnectivityManager) context.getSystemService(Context.CONNECTIVITY_SERVICE);
      decoder = new MediaCodecDecoderRenderer(
          activity,
          preferences,
          new CrashListener() {
            @Override
            public void notifyCrash(Exception error) {
              context.getSharedPreferences("DecoderTombstone", Context.MODE_PRIVATE)
                  .edit()
                  .putInt(
                      "CrashCount",
                      context.getSharedPreferences("DecoderTombstone", Context.MODE_PRIVATE)
                          .getInt("CrashCount", 0) + 1)
                  .commit();
            }
          },
          context.getSharedPreferences("DecoderTombstone", Context.MODE_PRIVATE)
              .getInt("CrashCount", 0),
          connectivity != null && connectivity.isActiveNetworkMetered(),
          hdr,
          glPreferences.glRenderer,
          this);
      if (!decoder.isAvcSupported()) {
        throw new IllegalStateException("H.264 decoder unavailable");
      }

      int videoFormats = MoonBridge.VIDEO_FORMAT_H264;
      if (decoder.isHevcSupported()) {
        videoFormats |= MoonBridge.VIDEO_FORMAT_H265;
        if (hdr && decoder.isHevcMain10Hdr10Supported()) {
          videoFormats |= MoonBridge.VIDEO_FORMAT_H265_MAIN10;
        }
      }
      if (decoder.isAv1Supported()) {
        videoFormats |= MoonBridge.VIDEO_FORMAT_AV1_MAIN8;
        if (hdr && decoder.isAv1Main10Supported()) {
          videoFormats |= MoonBridge.VIDEO_FORMAT_AV1_MAIN10;
        }
      }

      Display display = activity.getWindowManager().getDefaultDisplay();
      float refreshRate = Math.max(1.0f, display.getRefreshRate());
      int gamepadMask = preferences.multiController
          ? ControllerHandler.getAttachedControllerMask(context)
          : 1;
      if (preferences.onscreenController) {
        gamepadMask |= 1;
      }
      NvApp app = new NvApp(
          (String) args.get("appName"),
          (Integer) args.get("appId"),
          Boolean.TRUE.equals(args.get("hdr")));
      StreamConfiguration configuration = new StreamConfiguration.Builder()
          .setResolution(preferences.width, preferences.height)
          .setLaunchRefreshRate(preferences.fps)
          .setRefreshRate(preferences.fps)
          .setApp(app)
          .setBitrate(preferences.bitrate)
          .setEnableSops(preferences.enableSops)
          .enableLocalAudioPlayback(true)
          .setMaxPacketSize(1392)
          .setRemoteConfiguration(StreamConfiguration.STREAM_CFG_AUTO)
          .setSupportedVideoFormats(videoFormats)
          .setAttachedGamepadMask(gamepadMask)
          .setClientRefreshRateX100(Math.round(refreshRate * 100))
          .setAudioConfiguration(preferences.audioConfiguration)
          .setColorSpace(decoder.getPreferredColorSpace())
          .setColorRange(decoder.getPreferredColorRange())
          .setPersistGamepadsAfterDisconnect(!preferences.multiController)
          .build();
      X509Certificate certificate = (X509Certificate) CertificateFactory.getInstance("X.509")
          .generateCertificate(new ByteArrayInputStream((byte[]) args.get("serverCert")));
      connection = new NvConnection(
          context.getApplicationContext(),
          new ComputerDetails.AddressTuple((String) args.get("address"), (Integer) args.get("port")),
          0,
          (String) args.get("uniqueId"),
          configuration,
          PlatformBinding.getCryptoProvider(context),
          certificate);
      audio = new AndroidAudioRenderer(context, preferences.enableAudioFx);
      audio.setVolume(audioEnabled ? 1.0f : 0.0f);
      inputManager = (InputManager) context.getSystemService(Context.INPUT_SERVICE);
      keyboardTranslator = new KeyboardTranslator();
      inputManager.registerInputDeviceListener(keyboardTranslator, main);
      touchContexts[0] = preferences.touchscreenTrackpad
          ? new RelativeTouchContext(connection, 0, 1280, 720, streamView, preferences)
          : new AbsoluteTouchContext(connection, 0, streamView);
      touchContexts[1] = preferences.touchscreenTrackpad
          ? new RelativeTouchContext(connection, 1, 1280, 720, streamView, preferences)
          : new AbsoluteTouchContext(connection, 1, streamView);
      setStatus("connecting", (String) args.get("connectingLabel"));
    } catch (Exception error) {
      destroyInputControllers();
      if (inputManager != null && keyboardTranslator != null) {
        inputManager.unregisterInputDeviceListener(keyboardTranslator);
      }
      prepareDecoderForStop();
      preferences = null;
      connection = null;
      decoder = null;
      audio = null;
      controller = null;
      inputManager = null;
      keyboardTranslator = null;
      virtualController = null;
      setStatus("failed", errorLabel);
    }
    streamView.setOnTouchListener((view, event) -> handleTouchEvent(event));
  }

  public void setOnStateChanged(Runnable callback) {
    onStateChanged = callback;
  }

  public String getSessionState() {
    return sessionState;
  }

  public void setInputEnabled(boolean enabled) {
    inputLeaseGranted = enabled;
    boolean shouldEnable = enabled && !closed && connection != null && "playing".equals(sessionState);
    if (shouldEnable) {
      inputEnabled = true;
      if (!createInputControllers()) {
        inputEnabled = false;
        showInputUnavailable();
      } else {
        controller.enableSensors();
        if ("playing".equals(sessionState)) status.setVisibility(View.GONE);
      }
    } else {
      if (inputEnabled) releaseInput();
      inputEnabled = false;
      destroyInputControllers();
    }
    if (virtualController != null) {
      if (inputEnabled) virtualController.show();
      else virtualController.hide();
    }
    if (inputEnabled) {
      streamView.requestFocus();
    } else {
      streamView.clearFocus();
    }
  }

  public void setAudioEnabled(boolean enabled) {
    audioEnabled = enabled;
    if (audio != null) {
      audio.setVolume(enabled ? 1.0f : 0.0f);
    }
  }

  public void resetInput() {
    boolean restoreInput = inputEnabled && !closed && connection != null && "playing".equals(sessionState);
    if (!inputEnabled) return;
    releaseInput();
    if (!restoreInput) return;
    destroyInputControllers();
    if (createInputControllers()) {
      inputEnabled = true;
      controller.enableSensors();
      if (virtualController != null) virtualController.show();
      if ("playing".equals(sessionState)) status.setVisibility(View.GONE);
    } else {
      inputEnabled = false;
      streamView.clearFocus();
      showInputUnavailable();
    }
  }

  private boolean createInputControllers() {
    if (controller != null) return true;
    if (closed || connection == null || preferences == null || !"playing".equals(sessionState)) return false;
    try {
      controller = new ControllerHandler(activity, connection, this, preferences);
      if (preferences.onscreenController) {
        virtualController = new VirtualController(controller, this, activity);
        virtualController.refreshLayout();
        virtualController.hide();
      }
      return true;
    } catch (RuntimeException error) {
      destroyInputControllers();
      Log.e(TAG, "Could not initialize GameStream input", error);
      return false;
    }
  }

  private void destroyInputControllers() {
    if (virtualController != null) {
      virtualController.removeElements();
      virtualController = null;
    }
    if (controller != null) {
      controller.destroy();
      controller = null;
    }
  }

  private void showInputUnavailable() {
    main.post(() -> {
      if (closed || !"playing".equals(sessionState)) return;
      status.setText(label("inputUnavailableLabel", "Game input is unavailable."));
      status.setVisibility(View.VISIBLE);
    });
  }

  private void releaseInput() {
    for (TouchContext touch : touchContexts) {
      if (touch != null) {
        touch.cancelTouch();
        touch.setPointerCount(0);
      }
    }
    if (connection != null && "playing".equals(sessionState)) {
      for (short translated : heldKeys.values()) {
        connection.sendKeyboardInput(translated, KeyboardPacket.KEY_UP, (byte) 0, (byte) 0);
      }
      sendMouseButtonTransition(lastMouseButtonState, 0, MotionEvent.BUTTON_PRIMARY, MouseButtonPacket.BUTTON_LEFT);
      sendMouseButtonTransition(lastMouseButtonState, 0,
          MotionEvent.BUTTON_SECONDARY | MotionEvent.BUTTON_STYLUS_PRIMARY, MouseButtonPacket.BUTTON_RIGHT);
      sendMouseButtonTransition(lastMouseButtonState, 0,
          MotionEvent.BUTTON_TERTIARY | MotionEvent.BUTTON_STYLUS_SECONDARY, MouseButtonPacket.BUTTON_MIDDLE);
      sendMouseButtonTransition(lastMouseButtonState, 0, MotionEvent.BUTTON_BACK, MouseButtonPacket.BUTTON_X1);
      sendMouseButtonTransition(lastMouseButtonState, 0, MotionEvent.BUTTON_FORWARD, MouseButtonPacket.BUTTON_X2);
      lastMouseButtonState = 0;
      short mask = (short) ControllerHandler.getAttachedControllerMask(activity);
      for (short player = 0; player < 16; player++) {
        connection.sendControllerInput(player, mask, 0, (byte) 0, (byte) 0,
            (short) 0, (short) 0, (short) 0, (short) 0);
      }
    }
    heldKeys.clear();
    lastMouseButtonState = 0;
  }

  private boolean dispatchKeyDown(KeyEvent event) {
    if (!inputEnabled || closed || connection == null) {
      return false;
    }
    if (ControllerHandler.isGameControllerDevice(event.getDevice()) && controller != null
        && controller.handleButtonDown(event)) {
      return true;
    }
    short key = keyboardTranslator.translate(event.getKeyCode(), event.getDeviceId());
    if (key == 0 || event.getRepeatCount() > 0) {
      return false;
    }
    heldKeys.put(event.getKeyCode(), key);
    connection.sendKeyboardInput(key, KeyboardPacket.KEY_DOWN, modifiers(event),
        keyboardTranslator.hasNormalizedMapping(event.getKeyCode(), event.getDeviceId())
            ? (byte) 0 : MoonBridge.SS_KBE_FLAG_NON_NORMALIZED);
    return true;
  }

  private boolean dispatchKeyUp(KeyEvent event) {
    if (!inputEnabled || closed || connection == null) {
      return false;
    }
    if (ControllerHandler.isGameControllerDevice(event.getDevice()) && controller != null
        && controller.handleButtonUp(event)) {
      return true;
    }
    short key = keyboardTranslator.translate(event.getKeyCode(), event.getDeviceId());
    if (key == 0) {
      return false;
    }
    heldKeys.remove(event.getKeyCode());
    connection.sendKeyboardInput(key, KeyboardPacket.KEY_UP, modifiers(event),
        keyboardTranslator.hasNormalizedMapping(event.getKeyCode(), event.getDeviceId())
            ? (byte) 0 : MoonBridge.SS_KBE_FLAG_NON_NORMALIZED);
    return true;
  }

  private static byte modifiers(KeyEvent event) {
    byte value = 0;
    if (event.isShiftPressed()) value |= KeyboardPacket.MODIFIER_SHIFT;
    if (event.isCtrlPressed()) value |= KeyboardPacket.MODIFIER_CTRL;
    if (event.isAltPressed()) value |= KeyboardPacket.MODIFIER_ALT;
    if (event.isMetaPressed()) value |= KeyboardPacket.MODIFIER_META;
    return value;
  }

  private boolean handleMotionEvent(MotionEvent event) {
    if (!inputEnabled || closed || controller == null) {
      return false;
    }
    int source = event.getSource();
    if ((source & InputDevice.SOURCE_CLASS_JOYSTICK) != 0) {
      return controller.handleMotionEvent(event);
    }
    InputDevice device = event.getDevice();
    if (device != null && (device.getSources() & InputDevice.SOURCE_CLASS_JOYSTICK) != 0
        && controller.tryHandleTouchpadEvent(event)) {
      return true;
    }
    if ((source & InputDevice.SOURCE_CLASS_POINTER) == 0
        && (source & InputDevice.SOURCE_CLASS_POSITION) == 0
        && source != InputDevice.SOURCE_MOUSE_RELATIVE
        && source != 12290) {
      return false;
    }

    if (source == InputDevice.SOURCE_MOUSE_RELATIVE) {
      short deltaX = (short) event.getAxisValue(MotionEvent.AXIS_RELATIVE_X);
      short deltaY = (short) event.getAxisValue(MotionEvent.AXIS_RELATIVE_Y);
      if (deltaX != 0 || deltaY != 0) connection.sendMouseMove(deltaX, deltaY);
    } else if (event.getPointerCount() > 0 && streamView.getWidth() > 0 && streamView.getHeight() > 0) {
      short x = (short) Math.max(0, Math.min(streamView.getWidth() - 1, (int) event.getX()));
      short y = (short) Math.max(0, Math.min(streamView.getHeight() - 1, (int) event.getY()));
      connection.sendMousePosition(x, y, (short) streamView.getWidth(), (short) streamView.getHeight());
    }

    int buttons = event.getButtonState();
    if (source == 12290) {
      if (event.getActionMasked() == MotionEvent.ACTION_DOWN) buttons |= MotionEvent.BUTTON_PRIMARY;
      else if (event.getActionMasked() == MotionEvent.ACTION_UP) buttons &= ~MotionEvent.BUTTON_PRIMARY;
      else buttons |= lastMouseButtonState & MotionEvent.BUTTON_PRIMARY;
    }
    int changed = buttons ^ lastMouseButtonState;
    sendMouseButtonTransition(changed, buttons, MotionEvent.BUTTON_PRIMARY, MouseButtonPacket.BUTTON_LEFT);
    sendMouseButtonTransition(changed, buttons,
        MotionEvent.BUTTON_SECONDARY | MotionEvent.BUTTON_STYLUS_PRIMARY, MouseButtonPacket.BUTTON_RIGHT);
    sendMouseButtonTransition(changed, buttons,
        MotionEvent.BUTTON_TERTIARY | MotionEvent.BUTTON_STYLUS_SECONDARY, MouseButtonPacket.BUTTON_MIDDLE);
    if (preferences.mouseNavButtons) {
      sendMouseButtonTransition(changed, buttons, MotionEvent.BUTTON_BACK, MouseButtonPacket.BUTTON_X1);
      sendMouseButtonTransition(changed, buttons, MotionEvent.BUTTON_FORWARD, MouseButtonPacket.BUTTON_X2);
    }
    if (event.getActionMasked() == MotionEvent.ACTION_SCROLL) {
      connection.sendMouseHighResScroll((short) (event.getAxisValue(MotionEvent.AXIS_VSCROLL) * 120));
      connection.sendMouseHighResHScroll((short) (event.getAxisValue(MotionEvent.AXIS_HSCROLL) * 120));
    }
    lastMouseButtonState = buttons;
    return true;
  }

  private void sendMouseButtonTransition(int changed, int buttons, int mask, byte button) {
    if ((changed & mask) == 0) return;
    if ((buttons & mask) != 0) connection.sendMouseButtonDown(button);
    else connection.sendMouseButtonUp(button);
  }

  private boolean handleTouchEvent(MotionEvent event) {
    if (!inputEnabled || closed || connection == null) {
      return true;
    }
    if (event.getActionMasked() == MotionEvent.ACTION_CANCEL) {
      releaseInput();
      return true;
    }
    int index = event.getActionIndex();
    TouchContext current = index < touchContexts.length ? touchContexts[index] : null;
    int x = (int) event.getX(Math.min(index, event.getPointerCount() - 1));
    int y = (int) event.getY(Math.min(index, event.getPointerCount() - 1));
    switch (event.getActionMasked()) {
      case MotionEvent.ACTION_DOWN:
      case MotionEvent.ACTION_POINTER_DOWN:
        for (TouchContext touch : touchContexts) touch.setPointerCount(event.getPointerCount());
        if (current != null) current.touchDownEvent(x, y, event.getEventTime(), true);
        return true;
      case MotionEvent.ACTION_MOVE:
        for (int pointer = 0; pointer < Math.min(event.getPointerCount(), touchContexts.length); pointer++) {
          touchContexts[pointer].touchMoveEvent(
              (int) event.getX(pointer), (int) event.getY(pointer), event.getEventTime());
        }
        return true;
      case MotionEvent.ACTION_POINTER_UP:
      case MotionEvent.ACTION_UP:
        if (current != null) current.touchUpEvent(x, y, event.getEventTime());
        for (TouchContext touch : touchContexts) touch.setPointerCount(Math.max(0, event.getPointerCount() - 1));
        return true;
      default:
        return false;
    }
  }

  @Override
  public void toggleKeyboard() {
    if (inputEnabled) {
      InputMethodManager manager =
          (InputMethodManager) activity.getSystemService(Context.INPUT_METHOD_SERVICE);
      if (manager != null) manager.toggleSoftInput(0, 0);
    }
  }

  @Override
  public boolean handleKeyDown(KeyEvent event) {
    return dispatchKeyDown(event);
  }

  @Override
  public boolean handleKeyUp(KeyEvent event) {
    return dispatchKeyUp(event);
  }

  @Override
  public void onPerfUpdate(String text) {}

  @Override
  public void stageStarting(String stage) {
    if (closed) return;
    sessionState = "connecting";
    setStatus("connecting", label("connectingLabel", "Connecting…"));
  }

  @Override
  public void stageComplete(String stage) {}

  @Override
  public void stageFailed(String stage, int portFlags, int errorCode) {
    if (closed) return;
    sessionState = "failed";
    setStatus("failed", errorLabel);
    main.post(() -> setInputEnabled(false));
    prepareDecoderForStop();
    stopNativeAsync();
  }

  @Override
  public void connectionStarted() {
    if (closed) return;
    sessionState = "playing";
    setStatus("playing", "");
    main.post(() -> setInputEnabled(inputLeaseGranted));
  }

  @Override
  public void connectionTerminated(int errorCode) {
    if (closed) return;
    String state = errorCode == MoonBridge.ML_ERROR_GRACEFUL_TERMINATION ? "disconnected" : "failed";
    sessionState = state;
    setStatus(state, errorLabel);
    main.post(() -> setInputEnabled(false));
    prepareDecoderForStop();
    stopNativeAsync();
  }

  @Override
  public void connectionStatusUpdate(int connectionStatus) {}

  @Override
  public void displayMessage(String message) {}

  @Override
  public void displayTransientMessage(String message) {}

  @Override
  public void rumble(short controllerNumber, short lowFreqMotor, short highFreqMotor) {
    if (controller != null) controller.handleRumble(controllerNumber, lowFreqMotor, highFreqMotor);
  }

  @Override
  public void rumbleTriggers(short controllerNumber, short leftTrigger, short rightTrigger) {
    if (controller != null) controller.handleRumbleTriggers(controllerNumber, leftTrigger, rightTrigger);
  }

  @Override
  public void setHdrMode(boolean enabled, byte[] hdrMetadata) {
    if (decoder != null) decoder.setHdrMode(enabled, hdrMetadata);
  }

  @Override
  public void setMotionEventState(short controllerNumber, byte motionType, short reportRateHz) {
    if (controller != null) controller.handleSetMotionEventState(controllerNumber, motionType, reportRateHz);
  }

  @Override
  public void setControllerLED(short controllerNumber, byte r, byte g, byte b) {
    if (controller != null) controller.handleSetControllerLED(controllerNumber, r, g, b);
  }

  @Override
  public void surfaceCreated(SurfaceHolder holder) {}

  @Override
  public void surfaceChanged(SurfaceHolder holder, int format, int width, int height) {
    if (decoder == null || connection == null || closed || width <= 0 || height <= 0) return;
    decoder.setRenderTarget(holder);
    if (connectionStarted.compareAndSet(false, true)) {
      acquireWifiLocks();
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
        holder.getSurface().setFrameRate(preferences.fps, Surface.FRAME_RATE_COMPATIBILITY_FIXED_SOURCE,
            Surface.CHANGE_FRAME_RATE_ALWAYS);
      } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
        holder.getSurface().setFrameRate(preferences.fps, Surface.FRAME_RATE_COMPATIBILITY_FIXED_SOURCE);
      }
      audio.setVolume(audioEnabled ? 1.0f : 0.0f);
      connection.start(audio, decoder, this);
    }
  }

  @Override
  public void surfaceDestroyed(SurfaceHolder holder) {}

  public void close() {
    if (closed) return;
    closed = true;
    setInputEnabled(false);
    streamView.getHolder().removeCallback(this);
    if (inputManager != null && keyboardTranslator != null) {
      inputManager.unregisterInputDeviceListener(keyboardTranslator);
      inputManager = null;
      keyboardTranslator = null;
    }
    destroyInputControllers();
    prepareDecoderForStop();
    stopNativeAsync();
    setStatus("disconnected", "");
  }

  public void awaitTermination() throws InterruptedException {
    if (!stopped.await(12, TimeUnit.SECONDS)) {
      throw new IllegalStateException("Moonlight session is still stopping");
    }
  }

  private void stopNativeAsync() {
    if (!stopStarted.compareAndSet(false, true)) return;
    releaseWifiLocks();
    if (connection == null || !connectionStarted.get()) {
      if (connection != null) connection.stop();
      stopped.countDown();
      return;
    }
    Thread worker = new Thread(() -> {
      try {
        connection.stop();
      } finally {
        stopped.countDown();
      }
    }, "PleazyMoonlightStop");
    worker.setDaemon(true);
    worker.start();
  }

  @SuppressWarnings("deprecation")
  private void acquireWifiLocks() {
    synchronized (wifiLockGuard) {
      if (highPerfWifiLock != null || lowLatencyWifiLock != null) return;
      WifiManager wifi = (WifiManager) activity.getApplicationContext().getSystemService(Context.WIFI_SERVICE);
      if (wifi == null) return;
      try {
        highPerfWifiLock = wifi.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "Pleazy Moonlight High Perf");
        highPerfWifiLock.setReferenceCounted(false);
        highPerfWifiLock.acquire();
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
          lowLatencyWifiLock = wifi.createWifiLock(WifiManager.WIFI_MODE_FULL_LOW_LATENCY, "Pleazy Moonlight Low Latency");
          lowLatencyWifiLock.setReferenceCounted(false);
          lowLatencyWifiLock.acquire();
        }
      } catch (SecurityException error) {
        releaseWifiLocksLocked();
      }
    }
  }

  private void releaseWifiLocks() {
    synchronized (wifiLockGuard) {
      releaseWifiLocksLocked();
    }
  }

  private void releaseWifiLocksLocked() {
    if (lowLatencyWifiLock != null) {
      if (lowLatencyWifiLock.isHeld()) lowLatencyWifiLock.release();
      lowLatencyWifiLock = null;
    }
    if (highPerfWifiLock != null) {
      if (highPerfWifiLock.isHeld()) highPerfWifiLock.release();
      highPerfWifiLock = null;
    }
  }

  private void prepareDecoderForStop() {
    if (decoder != null && decoderStopping.compareAndSet(false, true)) {
      decoder.prepareForStop();
    }
  }

  private boolean canPresentHdr() {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return false;
    Display display = activity.getWindowManager().getDefaultDisplay();
    Display.HdrCapabilities caps = display.getHdrCapabilities();
    if (caps == null) return false;
    for (int type : caps.getSupportedHdrTypes()) {
      if (type == Display.HdrCapabilities.HDR_TYPE_HDR10) return true;
    }
    return false;
  }

  private String label(String key, String fallback) {
    Object value = labels.get(key);
    return value instanceof String ? (String) value : fallback;
  }

  private void setStatus(String state, String message) {
    main.post(() -> {
      if (closed && !state.equals("disconnected")) return;
      if (state.equals("playing")) {
        sessionState = state;
        status.setVisibility(View.GONE);
      } else {
        sessionState = state;
        status.setText(message == null || message.isEmpty() ? errorLabel : message);
        status.setVisibility(View.VISIBLE);
      }
      Runnable callback = onStateChanged;
      if (callback != null) callback.run();
    });
  }

  private int dp(int value) {
    return Math.round(value * getResources().getDisplayMetrics().density);
  }
}
