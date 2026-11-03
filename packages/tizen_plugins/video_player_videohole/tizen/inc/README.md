# Tizen EGL headers

The Tizen 6 IoT-Headed rootstrap used by the pinned Tizen SDK omits EGL headers,
although the TV plugin resolves EGL entry points with `dlopen` and `dlsym` at
runtime. These declarations let the Tizen cross-compiler type-check that ABI;
the plugin does not link against the host's EGL library.

The four Khronos headers are copied from the EGL Registry commit
[`e80a2e0050`](https://github.com/KhronosGroup/EGL-Registry/commit/e80a2e0050):

| Header | SHA-256 |
| --- | --- |
| `EGL/egl.h` | `42ef2c0fabd5bdf2654e7768f90ce4e9d49d0013e5b6ac984bf6d5f8afbb66c9` |
| `EGL/eglext.h` | `16850120313a5cb90e092e96a9542c16c67d31821fa0be896837d3886c90b0d5` |
| `EGL/eglplatform.h` | `25b5391655effcf363a38fa00c3154f356a3eab3d35dc067847875513cf1e441` |
| `KHR/khrplatform.h` | `7b1e01aaa7ad8f6fc34b5c7bdf79ebf5189bb09e2c4d2e79fc5d350623d11e83` |

The headers are licensed under Apache-2.0; see `LICENSES/Apache-2.0.txt` and
the SPDX notices in each header.
