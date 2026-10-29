/* Decode PGS/VobSub through FFmpeg, exporting palette-aware RGBA and original
 * display intervals. No OCR/model/network code lives in this helper.
 * Wire format (little endian): "PLZYBMP1", then repeated display records:
 * int64 start_ms, int64 end_ms (-1 means until next display), uint32 rect_count;
 * each rectangle: int32 x,y; uint32 width,height,forced,rgba_bytes; RGBA bytes.
 * A zero-rectangle record clears the display. EOF does not invent a last end.
 */
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>
#include <libavutil/mem.h>
#include <libavutil/time.h>
#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#endif

#define MAX_PIXELS (8 * 1024 * 1024)
#define MAX_MS INT64_C(3600000)
static int64_t deadline;
static int interrupted(void *unused) { (void)unused; return av_gettime_relative() > deadline; }
static void bytes(const void *data, size_t size) { if (fwrite(data, 1, size, stdout) != size) exit(3); }
static void u32(uint32_t value) {
    unsigned char out[4];
    for (int i = 0; i < 4; ++i) out[i] = (unsigned char)(value >> (i * 8));
    bytes(out, sizeof(out));
}
static void i64(int64_t value) {
    uint64_t bits = (uint64_t)value;
    unsigned char out[8];
    for (int i = 0; i < 8; ++i) out[i] = (unsigned char)(bits >> (i * 8));
    bytes(out, sizeof(out));
}

int main(int argc, char **argv) {
    if (argc != 3) return 2;
    char *endarg = NULL;
    errno = 0;
    long requested = strtol(argv[2], &endarg, 10);
    if (errno || !endarg || *endarg || requested < 0 || requested > 63) return 2;
#ifdef _WIN32
    _setmode(_fileno(stdout), _O_BINARY);
#endif
    av_log_set_level(AV_LOG_QUIET);
    av_max_alloc(256 * 1024 * 1024);
    deadline = av_gettime_relative() + INT64_C(1800) * AV_TIME_BASE;
    AVFormatContext *format = avformat_alloc_context();
    AVCodecContext *decoder = NULL;
    AVPacket *packet = NULL;
    AVDictionary *options = NULL;
    int status = 1, stream_index = -1, subtitle_index = 0;
    if (!format) goto cleanup;
    format->interrupt_callback.callback = interrupted;
    format->probesize = 8 * 1024 * 1024;
    format->max_analyze_duration = INT64_C(10) * AV_TIME_BASE;
    av_dict_set(&options, "protocol_whitelist", "file", 0);
    av_dict_set(&options, "format_whitelist", "sup,vobsub,matroska,webm,mpeg,mpegts,mov", 0);
    av_dict_set(&options, "enable_drefs", "0", 0);
    if (avformat_open_input(&format, argv[1], NULL, &options) < 0) goto cleanup;
    if (avformat_find_stream_info(format, NULL) < 0) goto cleanup;
    for (unsigned i = 0; i < format->nb_streams; ++i) {
        if (format->streams[i]->codecpar->codec_type == AVMEDIA_TYPE_SUBTITLE && subtitle_index++ == requested) {
            stream_index = (int)i;
            break;
        }
    }
    if (stream_index < 0) goto cleanup;
    AVStream *stream = format->streams[stream_index];
    enum AVCodecID codec_id = stream->codecpar->codec_id;
    if (codec_id != AV_CODEC_ID_HDMV_PGS_SUBTITLE && codec_id != AV_CODEC_ID_DVD_SUBTITLE) goto cleanup;
    const AVCodec *codec = avcodec_find_decoder(codec_id);
    if (!codec || !(decoder = avcodec_alloc_context3(codec))) goto cleanup;
    if (avcodec_parameters_to_context(decoder, stream->codecpar) < 0) goto cleanup;
    decoder->pkt_timebase = stream->time_base;
    decoder->max_pixels = MAX_PIXELS;
    decoder->thread_count = 1;
    if (avcodec_open2(decoder, codec, NULL) < 0 || !(packet = av_packet_alloc())) goto cleanup;
    const int standalone = strcmp(format->iformat->name, "sup") == 0 || strcmp(format->iformat->name, "vobsub") == 0;
    const int64_t origin = !standalone && format->start_time != AV_NOPTS_VALUE ? format->start_time : 0;
    if (origin < -INT64_C(1000000000000000) || origin > INT64_C(1000000000000000)) goto cleanup;
    if (format->duration != AV_NOPTS_VALUE && format->duration > MAX_MS * 1000) goto cleanup;
    bytes("PLZYBMP1", 8);
    unsigned displays = 0, packets = 0;
    int read_status;
    int64_t previous = -1;
    while ((read_status = av_read_frame(format, packet)) >= 0) {
        if (++packets > 5000000 || interrupted(NULL)) goto cleanup;
        if (packet->stream_index != stream_index) { av_packet_unref(packet); continue; }
        AVSubtitle subtitle = {0};
        int got = 0;
        const int result = avcodec_decode_subtitle2(decoder, &subtitle, &got, packet);
        if (result < 0) { avsubtitle_free(&subtitle); goto cleanup; }
        if (got) {
            int64_t pts = subtitle.pts;
            if (pts == AV_NOPTS_VALUE && packet->pts != AV_NOPTS_VALUE)
                pts = av_rescale_q(packet->pts, stream->time_base, AV_TIME_BASE_Q);
            if (pts == AV_NOPTS_VALUE || pts < -INT64_C(1000000000000000) || pts > INT64_C(1000000000000000) ||
                ++displays > 50000 || subtitle.num_rects > 32) {
                avsubtitle_free(&subtitle); goto cleanup;
            }
            const int64_t base = (pts - origin) / 1000;
            const int64_t start = base + subtitle.start_display_time;
            int64_t end = -1;
            if (subtitle.end_display_time > subtitle.start_display_time && subtitle.end_display_time < UINT32_MAX)
                end = base + subtitle.end_display_time;
            if (start < 0 || start < previous || start > MAX_MS || (end != -1 && (end <= start || end > MAX_MS))) {
                avsubtitle_free(&subtitle); goto cleanup;
            }
            previous = start;
            i64(start); i64(end); u32(subtitle.num_rects);
            uint64_t total_pixels = 0;
            for (unsigned n = 0; n < subtitle.num_rects; ++n) {
                AVSubtitleRect *rect = subtitle.rects[n];
                if (!rect || rect->type != SUBTITLE_BITMAP || rect->w <= 0 || rect->h <= 0 ||
                    rect->w > 4096 || rect->h > 2160 || rect->x < 0 || rect->y < 0 ||
                    rect->x > 8192 || rect->y > 8192 || rect->linesize[0] < rect->w ||
                    !rect->data[0] || !rect->data[1] || rect->nb_colors <= 0 || rect->nb_colors > 256) {
                    avsubtitle_free(&subtitle); goto cleanup;
                }
                total_pixels += (uint64_t)rect->w * (uint64_t)rect->h;
                if (total_pixels > MAX_PIXELS) { avsubtitle_free(&subtitle); goto cleanup; }
                u32((uint32_t)rect->x); u32((uint32_t)rect->y);
                u32((uint32_t)rect->w); u32((uint32_t)rect->h);
                u32((rect->flags & AV_SUBTITLE_FLAG_FORCED) != 0);
                u32((uint32_t)rect->w * (uint32_t)rect->h * 4);
                unsigned char row[4096 * 4];
                for (int y = 0; y < rect->h; ++y) {
                    for (int x = 0; x < rect->w; ++x) {
                        unsigned index = rect->data[0][(size_t)y * (size_t)rect->linesize[0] + (size_t)x];
                        if (index >= (unsigned)rect->nb_colors) { avsubtitle_free(&subtitle); goto cleanup; }
                        uint32_t color;
                        memcpy(&color, rect->data[1] + index * 4, 4); /* FFmpeg palette: native-endian ARGB. */
                        row[x * 4] = (unsigned char)(color >> 16);
                        row[x * 4 + 1] = (unsigned char)(color >> 8);
                        row[x * 4 + 2] = (unsigned char)color;
                        row[x * 4 + 3] = (unsigned char)(color >> 24);
                    }
                    bytes(row, (size_t)rect->w * 4);
                }
            }
            avsubtitle_free(&subtitle);
        }
        av_packet_unref(packet);
    }
    if (read_status == AVERROR_EOF && fflush(stdout) == 0) status = 0;
cleanup:
    av_packet_free(&packet);
    avcodec_free_context(&decoder);
    avformat_close_input(&format);
    av_dict_free(&options);
    return status;
}
