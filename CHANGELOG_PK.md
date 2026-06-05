# PKRTX changes to dxvk-remix

This fork (`pk-integration`) carries Painkiller-RTX-specific renderer + bridge changes on top of
NVIDIA's dxvk-remix. Newest first; folded into the unified PKRTX Steam build changelog.

## 0.3.2 - 2026-06-05  (build branch `0.3.2` @ fac5757e)
- DLFG: `rtx.dlfg.suspendForMenu` flag — menu/cutscene frame-gen suspend ANDs into `isDLFGEnabled()` alongside the user's `rtx.dlfg.enable`, so the proxy-driven menu suspend never clobbers a manual Alt+X frame-gen toggle.
- RTX: texture replacements now apply on the rasterized (UI/menu) draw path.
- USD capture: optional identity bind/rest pose for world-from-bind engines.
- Bridge rebuilt fresh as a matched pair with the renderer (release x86 client + x64 server); PDBs shipped in the build for crash symbolication.
