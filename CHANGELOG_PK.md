# PKRTX changes to dxvk-remix

This fork (`pk-integration`) carries Painkiller-RTX-specific renderer + bridge changes on top of
NVIDIA's dxvk-remix. Newest first; folded into the unified PKRTX Steam build changelog.

## 0.3.6 RC3 - 2026-07-06  (pk-integration @ 42bf5194)
- `rtx.materializationBudgetTrianglesPerFrame` (new, default 0/off; PK ships 500000) — per-frame bound on NEW-geometry materialization (upload + interleave + BLAS build). Over-budget draws are skipped statelessly and retried on following frames: original draws via the game's own resubmission, replacement prims via the new `ReplacementInstance::pendingMaterialization` pending-work flag, which bypasses the preserve path until every prim has materialized. Admission is under-budget-with-one-mesh-overshoot so a per-frame trickle of small new geometry (particles) cannot starve meshes larger than the budget. Kills the camera-rotation frame-spike burst (many culled entities' replacements re-materializing at once); evidence chain in `patches/Painkiller/findings/rotation-hitch/`.
- `rtx.logGeometryLifecycle` diagnostic (new, default off) — `[GeomLife]` log lines for BlasEntry / instance / replacement-instance creation and eviction with asset-rule hashes; used to identify which assets churn during camera motion.
- Ships with `rtx.numFramesToKeepBLAS = 3600` (geometry-data keep rides the same option — caches the expensive re-upload/BLAS-rebuild across cull gaps) and `numFramesToKeepInstances` at default 1 (2+ causes one-frame doubled additive particle quads = brightness pops).
- NRC restored: the `.trex` NRC/CUDA companion DLL set (NRC_Vulkan / cudart64_12 / nvrtc64_120_0 / nvrtc-builtins64_128) now ships matching the renderer's NRC SDK v0.14.1 pin — a renderer built after the NRC submodule bump against stale DLLs failed init at level load and silently fell back to Importance Sampled indirect.
- Bridge unchanged since 0.3.5 (same tree, no source delta); renderer + bridge remain a matched pair; PDBs shipped.

## 0.3.5 - 2026-07-03  (pk-integration @ 53171d9e, merged upstream main beca93cc)
- Brought the PK fork current with NVIDIA dxvk-remix `main` (beca93cc): [REMIX-5629] particle-emitter lerp discontinuity guard, [REMIX-5532] volumetric preset froxel-rebuild fix, [REMIX-5443] dome-light args fix, [REMIX-2244] pre-transformed-vertex UI fix, [REMIX-5640] invalidate-preserved-draw-calls option (+ the 0.3.4->0.3.5 upstream range).
- Split the experimental CPU-fed / legacy-particle-reconstruction renderer WIP onto `feature/cpu-fed-particle-system`; it is NOT in this release (it drove a VRAM / Opacity-Micromap out-of-memory driver crash under sustained load). The shipping renderer is the consolidated `pk-integration` line.
- Renderer + bridge rebuilt as a matched pair (`remix-main+53171d9e`); PDBs shipped. A Tracy-instrumented renderer twin is now produced alongside each release (dev profiling only, not shipped in the depot).

## 0.3.4 - 2026-06-24  (pk-integration @ 2e0339e8, rebased onto upstream main f3cf833a)
- DrawCallCache: pair world-space-bone skinned instances by a representative bone's world position (`rtx.assumeWorldSpaceSkinnedBones`, new, default off). For PK's world-space bones every same-type enemy shares an identical bind-pose centroid under identity `objectToWorld`, so the cache tiebreaker (`getTransformedCentroid(objectToWorld)`) could not disambiguate a crowd and instances aliased by draw order → a distance-swept one-frame motion-vector smear on skinned enemies. The option also collapses skinned `objectToWorld` to identity (world placement lives in the bones). Object-space-bone games are unaffected (default off). Root cause + verification: `patches/Painkiller/findings/flicker-rootcause/SWARM-PAIRING-CENTROID.md`.
- Advanced the PK fork to NVIDIA dxvk-remix `main` (f3cf833a): picks up [REMIX-5501] particle-system stale-clump fix and [REMIX-5604] clear previous transform for newly preserved instances (motion-vector correctness on the preserve path).
- Renderer + bridge rebuilt as a matched pair from the same tree (`remix-main+2e0339e8`); PDBs shipped.

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
