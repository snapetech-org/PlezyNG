PlezyNG's RomM adapter and software libretro host are GPL-3.0-or-later.
RomM itself remains a separately installed AGPL-3.0 service; no RomM frontend
source is copied into PlezyNG. Its player is served by the user's server.

The host's build pins libretro-common's API header (MIT) and miniaudio
(dual public domain/MIT-0). Distributions must retain their upstream notices.
Core libraries are separate distribution inputs. The default core recipe builds
Gambatte, mGBA and FCEUmm; retain each pinned source tree's license files,
corresponding source and notices. Snes9x and Genesis Plus GX have additional
license restrictions and are excluded from the default core staging recipe.
Do not distribute them without the required separate distribution review.

No firmware, game ROMs, proprietary SDKs or third-party game content is bundled.
The core catalog mapping in romm_core_catalog.dart records compatibility facts
from RomM 5.4.1. Browser runtime code remains supplied by RomM.
