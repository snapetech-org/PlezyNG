package com.edde746.plezy.exoplayer

import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.Timeline
import androidx.media3.common.audio.AudioProcessor.AudioFormat
import androidx.media3.common.audio.AudioProcessor.StreamMetadata
import androidx.media3.common.audio.BaseAudioProcessor
import androidx.media3.common.util.UnstableApi
import java.nio.ByteBuffer

/** Identity PCM processor before speed/silence processing, on Media3's window clock.
 * Output.write's presentation timestamp is for tunneling and is not a PCM clock.
 * StreamMetadata supplies the post-seek anchor; sample counts preserve that clock.
 */
@OptIn(UnstableApi::class)
internal class SubtitlePcmAudioProcessor(private val capture: SubtitlePcmCaptureBuffer) : BaseAudioProcessor() {
  @Volatile var ready = false
    private set
  private var frames = 0L
  private var anchorUs = 0L
  private var periodUid: Any? = null
  private var periodPositionUs = 0L

  override fun onConfigure(format: AudioFormat): AudioFormat =
    if (format.encoding == C.ENCODING_PCM_16BIT && format.sampleRate in 8000..192000 && format.channelCount in 1..8)
      format else AudioFormat.NOT_SET

  override fun onFlush(metadata: StreamMetadata) {
    frames = 0L
    anchorUs = metadata.positionOffsetUs
    periodUid = metadata.periodUid
    periodPositionUs = if (periodUid != null && metadata.timeline.getIndexOfPeriod(periodUid!!) != C.INDEX_UNSET)
      metadata.timeline.getPeriodByUid(periodUid!!, Timeline.Period()).positionInWindowUs else 0L
    ready = inputAudioFormat.encoding == C.ENCODING_PCM_16BIT && inputAudioFormat.sampleRate > 0
    capture.clearPackets()
  }

  override fun queueInput(input: ByteBuffer) {
    val bytes = input.remaining()
    val format = inputAudioFormat
    if (ready && bytes > 0) {
      capture.capture(input, bytes, anchorUs + frames * 1000000L / format.sampleRate,
        format.sampleRate, format.channelCount, format.encoding, periodUid, periodPositionUs)
      frames += bytes / (format.channelCount * 2)
    }
    replaceOutputBuffer(bytes).apply { put(input); flip() }
  }

  override fun onReset() { ready = false; frames = 0; periodUid = null; capture.clearPackets() }
}
