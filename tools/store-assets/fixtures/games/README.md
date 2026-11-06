# Steam gallery artwork

Library covers use the production `library_600x900.jpg` CDN path for app IDs
620 (Portal 2), 413150 (Stardew Valley), and 1145360 (Hades).

`stardew-gameplay.jpg` is the first screenshot returned by the public
[Steam store API for Stardew Valley](https://store.steampowered.com/api/appdetails?appids=413150):
[original gameplay frame](https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/413150/ss_b887651a93b0525739049eb4194f633de2df75be.1920x1080.jpg).
Artwork belongs to its respective publishers. The opt-in feature harness displays
this frame with production `SteamTouchControls`; the editor remains a separate
scene with its normal empty positioning canvas. This composition does not start
a native receiver or assert a connected host session.
