# Explicit installed-model sample check

The AI subtitle sheet has **Check this speech backend** beside its provider
selector. The viewer chooses a known WAV, optionally enters expected words and
explicitly starts inference. The sample must be 0.5–15 seconds and no larger than
8 MiB. It is copied into owned temporary storage and hashed; the original path
does not enter the report. Missing models are refused without a download.

The check runs the same chosen provider, inference scheduler and CPU fallback
path used by transcription. Its report records the requested provider, runtime
initialization report, whole-run fallback, declared model identity, sample digest,
recognized words and elapsed time including queueing/model loading. A blank
result is disclosed. Optional expected-text agreement ignores only case and
repeated whitespace; it is not WER, linguistic review or a quality score. The
elapsed/audio ratio is not an isolated inference benchmark or sustained-live
latency measurement. Neither a hardware name nor successful initialization is
treated as evidence of per-operation GPU/NPU placement.

Cancel, source/profile retirement or the two-minute inference admission budget
requests cooperative Whisper cancellation and discards the result. Other native
calls must return before their temporary input is removed. No provider or player
setting is changed and no caption is attached. An explicit JSON export includes
recognized/expected text and the sample digest, but not its path or credentials.

The check's source is implemented; it was not executed. No models, tests,
analyzers, builds or CI were run under the owner's code-only instruction.
