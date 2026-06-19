# PKRTX changes to dxvk-remix

This fork (`pk-integration`) carries Painkiller-RTX-specific renderer + bridge changes on top of
NVIDIA's dxvk-remix. Newest first; folded into the unified PKRTX Steam build changelog.

## Unreleased  (pk-integration)
- DrawCallCache: pair world-space-bone skinned instances by a representative bone's world position (`rtx.assumeWorldSpaceSkinnedBones`, new, default off). For PK's world-space bones every same-type enemy shares an identical bind-pose centroid under identity `objectToWorld`, so the cache tiebreaker (`getTransformedCentroid(objectToWorld)`) could not disambiguate a crowd and instances aliased by draw order → a distance-swept one-frame motion-vector smear on skinned enemies. The option also collapses skinned `objectToWorld` to identity (world placement lives in the bones). Object-space-bone games are unaffected (default off). Root cause + verification: `patches/Painkiller/findings/flicker-rootcause/SWARM-PAIRING-CENTROID.md`.

## 0.3.3 - 2026-06-17  (pk-integration @ 7af28ddb, rebased onto upstream main 2522e69a)
- Rebased the PK fork onto NVIDIA dxvk-remix upstream `main` (2522e69a): picks up the post-processing / composite refactor + REMIX-5261 fixes (+24 upstream commits).
- Re-applied the PK composite demodulate-mode (`computeEffectiveAlbedo`, `demodulateMode` / `demodulateAlbedoLuminanceFloor`) onto upstream's refactored composite pass; merged the `CompositeArgs` struct to carry both it and upstream's `writeRayReconstructionHitDistance`.
- Dropped the PK DLFG swap-chain recreate-loop fix — upstream now fixes the same bug itself (needed-images `!=` → `>`).
- Clean rebuild: embedded build stamp now matches source (`remix-main+7af28ddb`); renderer + bridge rebuilt as a matched pair with matching PDBs.

## 0.3.2 - 2026-06-05  (build branch `0.3.2` @ fac5757e)
- DLFG: `rtx.dlfg.suspendForMenu` flag — menu/cutscene frame-gen suspend ANDs into `isDLFGEnabled()` alongside the user's `rtx.dlfg.enable`, so the proxy-driven menu suspend never clobbers a manual Alt+X frame-gen toggle.
- RTX: texture replacements now apply on the rasterized (UI/menu) draw path.
- USD capture: optional identity bind/rest pose for world-from-bind engines.
- Bridge rebuilt fresh as a matched pair with the renderer (release x86 client + x64 server); PDBs shipped in the build for crash symbolication.
