package com.edde746.plezy.exoplayer

import androidx.media3.common.C
import java.nio.ByteBuffer
import java.util.ArrayDeque

/**
 * A bounded, opt-in copy of PCM that has already passed through Media3's
 * timestamped PCM processing path. Capture never advances or mutates the AudioTrack buffer.
 */
internal class SubtitlePcmCaptureBuffer(
  private val maxBufferedBytes: Int = 8 * 1024 * 1024
) {
  private data class Packet(
    val bytes: ByteArray,
    val presentationTimeUs: Long,
    val sampleRate: Int,
    val channels: Int,
    val encoding: String,
    val periodUid: Any?,
    val periodPositionUs: Long
  )

  private val lock = Any()
  private val packets = ArrayDeque<Packet>()
  private var bufferedBytes = 0

  @Volatile
  private var enabled = false

  fun setEnabled(value: Boolean) {
    synchronized(lock) {
      enabled = value
      packets.clear()
      bufferedBytes = 0
    }
  }

  fun clearPackets() = synchronized(lock) { packets.clear(); bufferedBytes = 0 }

  fun capture(
    source: ByteBuffer,
    byteCount: Int,
    presentationTimeUs: Long,
    sampleRate: Int,
    channels: Int,
    encoding: Int,
    periodUid: Any? = null,
    periodPositionUs: Long = 0L
  ) {
    if (!enabled || sampleRate !in 8_000..192_000 || channels !in 1..8) return
    val bytesPerSample = when (encoding) {
      C.ENCODING_PCM_16BIT -> 2
      C.ENCODING_PCM_FLOAT -> 4
      else -> return
    }
    val bytesPerFrame = bytesPerSample * channels
    val alignedBytes = minOf(byteCount, source.remaining())
    val frameAlignedBytes = alignedBytes - alignedBytes % bytesPerFrame
    if (frameAlignedBytes <= 0 || frameAlignedBytes > maxBufferedBytes) return

    val copy = ByteArray(frameAlignedBytes)
    source.duplicate().apply { limit(position() + frameAlignedBytes) }.get(copy)
    val packet = Packet(
      bytes = copy,
      presentationTimeUs = presentationTimeUs,
      sampleRate = sampleRate,
      channels = channels,
      encoding = if (encoding == C.ENCODING_PCM_FLOAT) "float32" else "pcm16",
      periodUid = periodUid, periodPositionUs = periodPositionUs
    )

    synchronized(lock) {
      if (!enabled) return
      while (bufferedBytes + copy.size > maxBufferedBytes && packets.isNotEmpty()) {
        bufferedBytes -= packets.removeFirst().bytes.size
      }
      packets.addLast(packet)
      bufferedBytes += copy.size
    }
  }

  fun drain(clock: (Long, Any?, Long) -> Pair<Long, Long?>?): List<Map<String, Any>> = synchronized(lock) {
    val result = ArrayList<Map<String, Any>>(packets.size)
    while (packets.isNotEmpty()) {
      val packet = packets.removeFirst()
      bufferedBytes -= packet.bytes.size
      val mapped = clock(packet.presentationTimeUs, packet.periodUid, packet.periodPositionUs) ?: continue
      result.add(
        hashMapOf<String, Any>(
          "pcm" to packet.bytes,
          "presentationTimeUs" to mapped.first,
          "sampleRate" to packet.sampleRate,
          "channels" to packet.channels,
          "encoding" to packet.encoding
        ).apply { mapped.second?.let { put("clockOriginUs", it) } }
      )
    }
    result
  }
}
