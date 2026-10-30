# Broadcast caption derivatives

The companion exposes `closed_captions` only when an administrator-installed
CCExtractor executable is available (`PLEZY_CCEXTRACTOR` or `ccextractor`). The
app offers one CEA-608 channel CC1–CC4 or one CEA-708 service 1–63. An optional
transport-stream program number is bounded to 1–65535. The wrapper does not use
multi-program auto-selection; ambiguous transport streams fail for an explicit
choice instead of silently selecting a different program/language.

Only uploaded media is passed as an input. Fixed command arguments request UTF-8
SRT on stdout, disable teletext/DVB fallback and heuristic typo correction, and
stop at the first hour. Output is bounded to 5 MiB, 50,000 cues and 4000 characters
per cue, with a thirty-minute subprocess deadline. Every block must parse and
have a valid clock; malformed output cannot silently lose captions. No arbitrary
client flags, file paths, URLs or commands enter the invocation. Source-owned
multipart uploads add their opened-part offset once through the existing result
handoff. Service, program, decoder version, output digest and clock basis enter
the research review/export before ordinary text review and attachment.

This is a flattened text derivative. Native CEA window layout, colors, overlap
presentation, roll-up/pop-on/paint-on and broadcaster clock/discontinuity behavior
are not preserved in SRT. It neither replaces the native caption renderer nor
claims full CEA conformance. The installed decoder's language/service/container
coverage and clocks require qualification.

The source-built palette-aware bitmap helper now accepts DVB bitmap streams in
addition to PGS and VobSub. If its linked FFmpeg has libzvbi, it can decode **one
explicit teletext page** (100–899) to RGBA. The app selects the stream ordinal and
page separately. Page images, display intervals and OCR correction use the
existing bounded bitmap review. The helper refuses a teletext stream without a
page, or a page parameter for another codec. Revision-2 capability discovery
advertises only linked DVB/teletext decoders; older binaries do not expose the
new teletext control. There is no new binary or dependency pin in this change.

References: [CCExtractor command line](https://ccextractor.org/public/general/command_line_usage/)
and [FFmpeg subtitle decoder options](https://ffmpeg.org/ffmpeg-codecs.html#Subtitles-Decoders).
No decoder, fixture, package installation, test, analyzer or build was run.
