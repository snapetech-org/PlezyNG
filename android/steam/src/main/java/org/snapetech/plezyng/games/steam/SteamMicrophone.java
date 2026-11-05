// SPDX-License-Identifier: GPL-3.0-or-later
package org.snapetech.plezyng.games.steam;

import android.media.AudioFormat;
import android.media.AudioRecord;
import android.media.MediaRecorder;
import java.util.Arrays;

/** Per-session opt-in microphone. The native lease is revoked on ownership loss. */
final class SteamMicrophone {
  static boolean start(long handle) {
    long[] lease = NativeSteam.microphoneBegin(handle);
    if (lease == null || lease.length != 3 || lease[0] == 0)
      return false;
    try {
      Thread thread = new Thread(() -> capture(handle, lease), "PlezySteamMicrophone");
      thread.setDaemon(true);
      thread.start();
      return true;
    } catch (RuntimeException error) {
      NativeSteam.microphoneFinish(handle, lease[0]);
      return false;
    }
  }
  private static void capture(long handle, long[] lease) {
    AudioRecord record = null;
    short[] pcm = new short[11520];
    final long epoch = lease[0];
    try {
      final int rate = (int) lease[1], channels = (int) lease[2];
      final int mask = channels == 1 ? AudioFormat.CHANNEL_IN_MONO : AudioFormat.CHANNEL_IN_STEREO;
      int minimum = AudioRecord.getMinBufferSize(rate, mask, AudioFormat.ENCODING_PCM_16BIT);
      if (minimum <= 0 || minimum > rate * channels || !NativeSteam.microphoneCurrent(handle, epoch))
        return;
      record = new AudioRecord(
          MediaRecorder.AudioSource.VOICE_COMMUNICATION, rate, mask, AudioFormat.ENCODING_PCM_16BIT,
          Math.max(minimum, rate * channels / 5));
      if (record.getState() != AudioRecord.STATE_INITIALIZED || !NativeSteam.microphoneCurrent(handle, epoch))
        return;
      record.startRecording();
      if (record.getRecordingState() != AudioRecord.RECORDSTATE_RECORDING)
        return;
      long last = android.os.SystemClock.elapsedRealtime();
      while (NativeSteam.microphoneCurrent(handle, epoch)) {
        int count = record.read(pcm, 0, pcm.length, AudioRecord.READ_NON_BLOCKING);
        if (count < 0 || count % channels != 0)
          break;
        if (count == 0) {
          if (android.os.SystemClock.elapsedRealtime() - last > 3000)
            break;
          Thread.sleep(5);
          continue;
        }
        last = android.os.SystemClock.elapsedRealtime();
        boolean sent = NativeSteam.microphonePcm(handle, epoch, pcm, count);
        Arrays.fill(pcm, (short) 0);
        if (!sent)
          break;
      }
    } catch (InterruptedException error) {
      Thread.currentThread().interrupt();
    } catch (RuntimeException error) {
      // Permission withdrawal and missing/busy devices leave the session muted.
      // Never record audio or device details in logs.
    } finally {
      if (record != null) {
        try {
          record.stop();
        } catch (RuntimeException ignored) {
        }
        record.release();
      }
      Arrays.fill(pcm, (short) 0);
      NativeSteam.microphoneFinish(handle, epoch);
    }
  }
  private SteamMicrophone() {}
}
