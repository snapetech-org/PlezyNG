// SPDX-License-Identifier: GPL-3.0-or-later
package org.snapetech.plezyng.games.steam;

import java.util.Map;

/** Bounded optional arguments; older Flutter/Activity callers retain defaults. */
final class SteamStreamOptions {
  final int width, height, fps, bitrateKbps, controllerCount, audioChannels;
  final boolean allowHevc, allowHdr;
  final int[] relayPorts = new int[6];

  private SteamStreamOptions(Map<?, ?> args) {
    for (int i = 0; i < 6; ++i) relayPorts[i] = integer(args, "relayPort" + i, 0, 1, 65535);
    width = integer(args, "streamWidth", 1920, 640, 3840);
    height = integer(args, "streamHeight", 1080, 360, 2160);
    fps = integer(args, "streamFps", 60, 15, 120);
    bitrateKbps = integer(args, "streamBitrateKbps", 30000, 1000, 100000);
    controllerCount = integer(args, "controllerCount", 1, 1, 4);
    audioChannels = integer(args, "audioChannels", 2, 2, 6);
    if (audioChannels != 2 && audioChannels != 4 && audioChannels != 6)
      throw new IllegalArgumentException("Invalid audio layout");
    if (width % 2 != 0 || height % 2 != 0) throw new IllegalArgumentException("Invalid stream dimensions");
    Object hevc = args.get("allowHevc");
    if (hevc != null && !(hevc instanceof Boolean)) throw new IllegalArgumentException("Invalid codec option");
    allowHevc = !Boolean.FALSE.equals(hevc);
    Object hdr = args.get("allowHdr");
    if (hdr != null && !(hdr instanceof Boolean)) throw new IllegalArgumentException("Invalid HDR option");
    allowHdr = Boolean.TRUE.equals(hdr);
  }

  static SteamStreamOptions from(Map<?, ?> args) { return new SteamStreamOptions(args); }

  private static int integer(Map<?, ?> args, String key, int fallback, int min, int max) {
    Object value = args.get(key);
    if (value == null) return fallback;
    if (!(value instanceof Integer) && !(value instanceof Long)) throw new IllegalArgumentException("Invalid stream limit");
    long number = ((Number) value).longValue();
    if (number < min || number > max) throw new IllegalArgumentException("Stream limit out of range");
    return (int) number;
  }
}
