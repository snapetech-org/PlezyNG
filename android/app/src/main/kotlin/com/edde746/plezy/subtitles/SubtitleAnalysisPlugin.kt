package com.edde746.plezy.subtitles

import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaDataSource
import android.media.MediaExtractor
import android.media.MediaFormat
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.FileInputStream
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.nio.ByteOrder
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.ceil
import kotlin.math.roundToInt

/** A private analysis decoder. It creates no AudioTrack, Surface or audio focus request. */
class SubtitleAnalysisPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
  private var channel: MethodChannel? = null
  private val worker = Executors.newSingleThreadExecutor()
  private val main = Handler(Looper.getMainLooper())
  private var active: Pair<String, AtomicBoolean>? = null // Main-thread admission/cancellation.

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    channel = MethodChannel(binding.binaryMessenger, "com.plezy/subtitle_analysis").also { it.setMethodCallHandler(this) }
  }
  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    active?.second?.set(true)
    channel?.setMethodCallHandler(null); channel = null
    worker.shutdown()
  }
  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    if (call.method == "capabilities") {
      result.success(mapOf("version" to 1, "backend" to "Android MediaExtractor/MediaCodec", "maxWindowMs" to 64000)); return
    }
    val id = call.argument<String>("id")
    if (call.method == "cancel") { if (active?.first == id) active?.second?.set(true); result.success(null); return }
    if (call.method != "decode") { result.notImplemented(); return }
    val uri = call.argument<String>("uri")?.let { Uri.parse(it) }
    val start = call.argument<Number>("startMs")?.toLong()
    val end = call.argument<Number>("endMs")?.toLong()
    val ordinal = call.argument<Number>("audioOrdinal")?.toInt()
    if (id == null || !Regex("^[a-f0-9]{32}$").matches(id) || uri == null || uri.userInfo != null || uri.fragment != null ||
        !(uri.scheme == "file" && (uri.host.isNullOrEmpty()) || uri.scheme == "http" && uri.host == "127.0.0.1") ||
        start == null || end == null || start < 0 || end <= start || end > 28800000 || end-start > 64000 ||
        ordinal == null || ordinal !in 0..63) {
      result.error("ANALYSIS_ARGUMENTS", "Invalid owned source or bounded audio window", null); return
    }
    if (active != null) { result.error("ANALYSIS_BUSY", "Another analysis decoder is closing or active", null); return }
    val cancelled = AtomicBoolean(false)
    active = id to cancelled
    worker.execute {
      try {
        val pcm = decode(uri, start, end, ordinal, cancelled)
        main.post { if (active?.first == id) active = null
          if (channel != null) result.success(pcm) }
      } catch (_: Exception) {
        main.post { if (active?.first == id) active = null
          if (channel != null) result.error("ANALYSIS_DECODE", "Native audio decoding failed, timed out, was cancelled, or encountered an unsupported/protected source", null) }
      }
    }
  }

  private fun decode(uri: Uri, startMs: Long, endMs: Long, ordinal: Int, cancelled: AtomicBoolean): ByteArray {
    val extractor = MediaExtractor()
    var decoder: MediaCodec? = null
    var ownedHttp: OwnedAnalysisHttpSource? = null
    val deadline = SystemClock.elapsedRealtime() + 90000
    fun current() { check(!cancelled.get() && SystemClock.elapsedRealtime() < deadline) }
    try {
      current()
      if (uri.scheme == "file") FileInputStream(requireNotNull(uri.path)).use { extractor.setDataSource(it.fd) }
      else {
        val source = OwnedAnalysisHttpSource(uri.toString(), cancelled, deadline)
        ownedHttp = source; extractor.setDataSource(source)
      }
      current()
      val audio = (0 until extractor.trackCount).filter { extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true }
      val index = audio.getOrNull(ordinal) ?: error("Audio stream missing")
      val format = extractor.getTrackFormat(index)
      val mime = requireNotNull(format.getString(MediaFormat.KEY_MIME))
      require(!mime.contains("scrambled"))
      extractor.selectTrack(index)
      extractor.seekTo(startMs * 1000, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
      format.setInteger(MediaFormat.KEY_PCM_ENCODING, AudioFormat.ENCODING_PCM_16BIT)
      val codec = MediaCodec.createDecoderByType(mime)
      decoder = codec
      codec.configure(format, null, null, 0); codec.start()
      val count = ((endMs - startMs) * 16).toInt()
      val output = ByteArray(count * 2)
      val populated = BooleanArray(count)
      var inputEnded = false
      var outputEnded = false
      var sampleRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
      var channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
      var encoding = AudioFormat.ENCODING_PCM_16BIT
      val info = MediaCodec.BufferInfo()
      while (!outputEnded) {
        current()
        if (!inputEnded) {
          val slot = codec.dequeueInputBuffer(10000)
          if (slot >= 0) {
            val buffer = requireNotNull(codec.getInputBuffer(slot)); buffer.clear()
            val time = extractor.sampleTime
            if (time < 0 || time > endMs * 1000 + 250000) {
              codec.queueInputBuffer(slot, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM); inputEnded = true
            } else {
              require(extractor.sampleFlags and MediaExtractor.SAMPLE_FLAG_ENCRYPTED == 0)
              val size = extractor.readSampleData(buffer, 0)
              if (size < 0) { codec.queueInputBuffer(slot, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM); inputEnded = true }
              else { codec.queueInputBuffer(slot, 0, size, time, 0); extractor.advance() }
            }
          }
        }
        val slot = codec.dequeueOutputBuffer(info, 10000)
        if (slot == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
          val changed = codec.outputFormat
          sampleRate = changed.getInteger(MediaFormat.KEY_SAMPLE_RATE)
          channels = changed.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
          encoding = if (changed.containsKey(MediaFormat.KEY_PCM_ENCODING)) changed.getInteger(MediaFormat.KEY_PCM_ENCODING) else AudioFormat.ENCODING_PCM_16BIT
        } else if (slot >= 0) {
          try {
            require(sampleRate in 8000..192000 && channels in 1..8)
            val bytesPerSample = when (encoding) { AudioFormat.ENCODING_PCM_16BIT -> 2; AudioFormat.ENCODING_PCM_FLOAT -> 4; else -> error("PCM encoding") }
            if (info.size > 0 && info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0) {
              val raw = requireNotNull(codec.getOutputBuffer(slot)).duplicate().order(ByteOrder.LITTLE_ENDIAN)
              require(info.size <= 4 * 1024 * 1024 && info.size % (channels * bytesPerSample) == 0)
              val frames = info.size / (channels * bytesPerSample)
              fun mono(frame: Int): Double {
                var sum = 0.0
                for (channel in 0 until channels) {
                  val offset = info.offset + (frame * channels + channel) * bytesPerSample
                  val value = if (bytesPerSample == 2) raw.getShort(offset) / 32768.0 else raw.getFloat(offset).toDouble()
                  sum += if (value.isFinite()) value.coerceIn(-1.0, 1.0) else 0.0
                }
                return sum / channels
              }
              val first = ceil((info.presentationTimeUs - startMs * 1000) * .016).toInt().coerceIn(0, count)
              val last = ceil((info.presentationTimeUs + frames * 1000000.0 / sampleRate - startMs * 1000) * .016).toInt().coerceIn(0, count)
              for (target in first until last) {
                val position = ((startMs * 1000 + target * 62.5 - info.presentationTimeUs) * sampleRate / 1000000.0).coerceIn(0.0, (frames-1).toDouble())
                val left = position.toInt(); val right = (left + 1).coerceAtMost(frames - 1)
                val fraction = position - left
                val value = ((mono(left) * (1-fraction) + mono(right) * fraction) * 32767).roundToInt().coerceIn(-32768, 32767)
                output[target*2] = value.toByte(); output[target*2+1] = (value shr 8).toByte(); populated[target] = true
              }
            }
            outputEnded = info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0 || info.presentationTimeUs >= endMs * 1000
          } finally { codec.releaseOutputBuffer(slot, false) }
        }
      }
      current()
      var gap = 0; var longestGap = 0
      for (present in populated) { gap = if (present) 0 else gap + 1; longestGap = maxOf(gap, longestGap) }
      require(populated.any { it } && longestGap <= 4000) // At most 250 ms codec priming/gap padding.
      return output
    } finally {
      try { decoder?.stop() } catch (_: Exception) {}
      try { decoder?.release() } finally { try { extractor.release() } finally { ownedHttp?.close() } }
    }
  }
}

/** Range reads stay on the source-owned loopback gateway; no redirects/cookies. */
private class OwnedAnalysisHttpSource(private val uri: String, private val cancelled: AtomicBoolean,
    private val deadline: Long) : MediaDataSource() {
  @Volatile private var closed = false
  private var length = -1L
  private fun connection(method: String): HttpURLConnection {
    if (closed || cancelled.get() || SystemClock.elapsedRealtime() >= deadline) throw IOException("Analysis source expired")
    return (URL(uri).openConnection() as HttpURLConnection).apply {
      requestMethod = method; connectTimeout = 10000; readTimeout = 10000
      instanceFollowRedirects = false; useCaches = false
      setRequestProperty("Accept-Encoding", "identity")
    }
  }
  @Synchronized override fun getSize(): Long {
    if (length >= 0) return length
    val request = connection("HEAD")
    try {
      if (request.responseCode != 200) throw IOException("Owned source did not expose a file length")
      length = request.getHeaderField("Content-Length")?.toLongOrNull() ?: -1L
      if (length <= 0 || length > (1L shl 40)) throw IOException("Owned source length is invalid")
      return length
    } finally { request.disconnect() }
  }
  @Synchronized override fun readAt(position: Long, buffer: ByteArray, offset: Int, size: Int): Int {
    if (position < 0 || offset < 0 || size < 0 || offset > buffer.size - size) throw IOException("Invalid analysis read")
    if (size == 0) return 0
    val total = getSize()
    if (position >= total) return -1
    val count = minOf(size.toLong(), 256L*1024, total-position).toInt()
    val request = connection("GET")
    request.setRequestProperty("Range", "bytes=$position-${position+count-1}")
    try {
      if (request.responseCode != 206 || request.getHeaderField("Content-Range") != "bytes $position-${position+count-1}/$total" ||
          request.getHeaderField("Content-Encoding")?.let { it != "identity" } == true) throw IOException("Owned source refused exact range")
      var read = 0
      request.inputStream.use { stream ->
        while (read < count) {
          if (closed || cancelled.get() || SystemClock.elapsedRealtime() >= deadline) throw IOException("Analysis source expired")
          val next = stream.read(buffer, offset+read, count-read)
          if (next < 0) throw IOException("Owned range was truncated")
          read += next
        }
      }
      return read
    } finally { request.disconnect() }
  }
  override fun close() { closed = true }
}
