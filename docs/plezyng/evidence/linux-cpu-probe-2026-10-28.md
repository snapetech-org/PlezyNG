# Linux CPU provider probe — 2026-10-28

The PME diagnostic opened the 540p ANVIL-S model through ONNX Runtime's
`CPUExecutionProvider` on `kspls0`. It used one intra-op thread, three warm-ups,
and twelve timed inferences. The run passed `--cpu-only` with `-` as the provider
manifest, so no accelerator provider was attempted.

```json
{
  "provider": "CPUExecutionProvider",
  "vendor": "",
  "device": "CPU",
  "cpu_execution": true,
  "cpu_fallback": false,
  "cpu_only": true,
  "input_elements": 3110400,
  "output_elements": 1555200,
  "warmups": 3,
  "iterations": 12,
  "session_open_ms": 23.568,
  "inference_ms": {
    "median": 317.831,
    "p95": 343.899,
    "mean": 320.096
  }
}
```

The inference median is well above the 41.67 ms interval for a 24 fps source
pair and the 33.33 ms interval for 30 fps. CPU execution is therefore validated
as an explicit diagnostic/runtime option, not as a real-time playback route.
The measurement does not qualify other CPU models or devices.

## Intra-op thread scaling on kspld0

A Release probe was built from this checkout against the pinned ONNX Runtime
1.27.1 x64 SDK/runtime. The CPU-only run used the same 540p ANVIL-S model, three
warm-ups, and twelve timed inferences per setting. No accelerator provider was
attempted and CPU fallback remained disabled. The probe's new
`--intra-op-threads N` option controls only this diagnostic run; playback
defaults remain unchanged.

| Intra-op threads | Median (ms) | p95 (ms) | Mean (ms) |
| ---: | ---: | ---: | ---: |
| 1 | 294.384 | 326.083 | 298.280 |
| 2 | 156.039 | 168.461 | 156.439 |
| 4 | 135.826 | 156.094 | 139.653 |
| 6 | 81.255 | 88.152 | 80.739 |
| 8 | 80.826 | 92.603 | 81.212 |
| 10 | 95.053 | 130.888 | 98.312 |
| 12 | 71.021 | 80.873 | 69.970 |
| 14 | 88.144 | 112.126 | 90.458 |
| 16 | 96.783 | 125.862 | 101.197 |

Twelve threads was the fastest measured setting, but its 80.873 ms p95 still
exceeds both source-pair budgets before frame preparation or reconstruction.
This confirms that CPU inference remains outside real-time Neural playback on
this host and model; thread scaling does not change the CPU-only fallback policy.
