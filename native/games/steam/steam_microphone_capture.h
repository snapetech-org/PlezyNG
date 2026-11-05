// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include "steam_runtime.h"
namespace plezy::steam {
// Called only after explicit permission/consent and current input ownership.
// Returns acceptance, not device/transport success; microphoneState is the
// authoritative state. Device work is off the UI thread, bounded and ephemeral.
bool startMicrophoneCapture(std::shared_ptr<Runtime> runtime);
}
