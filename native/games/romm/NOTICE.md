Pleazyng's RomM adapter and software libretro host are GPL-3.0-or-later.
RomM itself remains a separately installed AGPL-3.0 service; no RomM frontend
source is copied into Pleazyng. Its player is served by the user's server.

The host's build pins libretro-common's API header (MIT) and miniaudio
(dual public domain/MIT-0). Distributions must retain their upstream notices.
Normal application builds include Gambatte, mGBA and FCEUmm from immutable
source pins. The packages retain each source tree's license files, exact
corresponding source archives, host implementation/header notices and build
recipe. Additional cores remain separate distribution inputs. Snes9x and Genesis Plus GX have additional
license restrictions and are excluded from the default core staging recipe.
Do not distribute them without the required separate distribution review.

No firmware, game ROMs, proprietary SDKs or third-party game content is bundled.
The core catalog mapping in romm_core_catalog.dart records compatibility facts
from RomM 5.4.1. Browser runtime code remains supplied by RomM.
