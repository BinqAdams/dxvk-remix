/*
* Copyright (c) 2022-2026, NVIDIA CORPORATION. All rights reserved.
*
* Permission is hereby granted, free of charge, to any person obtaining a
* copy of this software and associated documentation files (the "Software"),
* to deal in the Software without restriction, including without limitation
* the rights to use, copy, modify, merge, publish, distribute, sublicense,
* and/or sell copies of the Software, and to permit persons to whom the
* Software is furnished to do so, subject to the following conditions:
*
* The above copyright notice and this permission notice shall be included in
* all copies or substantial portions of the Software.
*
* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
* IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
* FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL
* THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
* LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
* FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
* DEALINGS IN THE SOFTWARE.
*/

//!variant rtxdi_initial_sampling.comp
//!>       RTXDI_NO_PORTALS=0

//!variant rtxdi_initial_sampling_no_portals.comp
//!>       RTXDI_NO_PORTALS=1

//!end-variants

#define USE_32BIT_RAY_DIRECTION 1
#define RAB_HAS_CURRENT_GBUFFER 1
#define RAB_HAS_RTXDI_RESERVOIRS 1
#define RTXDI_DEFER_INITIAL_VISIBILITY 1

#include "rtx/pass/common_bindings.slangh"
#include "rtx/pass/rtxdi/rtxdi_reuse_bindings.slangh"

#include "rtx/utility/common.slangh"
#include "rtx/utility/noise.slangh"
#include "rtx/utility/math.slangh"
#include "rtx/utility/texture.slangh"
#include "rtx/utility/sampling.slangh"
#include "rtx/utility/packing.slangh"
#include "rtx/concept/ray/ray.slangh"
#include "rtx/concept/surface/surface.slangh"
#include "rtx/concept/surface_material/surface_material.slangh"
#include "rtx/concept/light/light.slangh"
#include "rtx/algorithm/resolve.slangh"
#include "rtx/algorithm/rtxdi/rtxdi.slangh"
#include "rtx/pass/sparse_rendering/compact_active_pixels.slangh"

[shader("compute")]
[numthreads(16, 8, 1)]
void main(int2 threadIndex : SV_DispatchThreadID)
{
  if (any(threadIndex >= cb.camera.resolution))
  {
    return;
  }

  uvec2 remapped;
  const bool isActive = loadPixelCoordinate(uint2(threadIndex), DirectActiveLocalPixelCoords,
    cb.camera.resolution, cb.sparseRenderingArgs, remapped);
  int2 pixelCoordinate = int2(remapped);

  // Inactive pixels are handled by the temporal reuse pass (cheap reprojection or skip).
  if (!isActive)
  {
    return;
  }

  RAB_Surface surface = RAB_GetGBufferSurface(pixelCoordinate, false);
  if (!RAB_IsSurfaceValid(surface))
  {
    return;
  }

  RAB_RandomSamplerState rng = RAB_InitRandomSampler(pixelCoordinate, cb.frameIdx, 2);

  vec2 screenSpaceMotion = PrimaryScreenSpaceMotionVector[pixelCoordinate];
  ivec2 prevPixelCenter = pixelCoordinate + ivec2(screenSpaceMotion.xy);

  uint16_t previousBestLightIndex = RTXDI_INVALID_LIGHT_INDEX;
  uint8_t previousBestLightPortalIdx = RTXDI_INVALID_PORTAL_INDEX;
  if (all(prevPixelCenter >= 0) && all(prevPixelCenter < cb.camera.resolution) && cb.enableRtxdiBestLightSampling)
  {
    uint2 previousBestLight = RtxdiBestLights[prevPixelCenter / RTXDI_GRAD_FACTOR];

    // Map the previous light index to the current frame, make sure the portal still exists if that light was a cross-portal one
#if RTXDI_NO_PORTALS
    if (previousBestLight.x != RTXDI_INVALID_LIGHT_INDEX && previousBestLight.y == RTXDI_INVALID_PORTAL_INDEX)
#else
    if (previousBestLight.x != RTXDI_INVALID_LIGHT_INDEX && (previousBestLight.y == RTXDI_INVALID_PORTAL_INDEX || previousBestLight.y < cb.numActiveRayPortals))
#endif
    {
      previousBestLightIndex = RAB_TranslateLightIndex(previousBestLight.x, /* currentToPrevious = */ false);
      previousBestLightPortalIdx = previousBestLight.y;
    }
  }

  RTXDI_Reservoir state = RTXDI_EmptyReservoir();
  if (cb.lightCount != 0)
  {
    // MegaLights two-reservoir partition: per-type RIS routes candidates
    // into `state` (main) and `outlierState` (distant lights + intensity
    // outliers) based on RAB_IsOutlierLight. See ResamplingFunctions.slangh
    // and D:/VRE3/Docs/RTXDIResearch.md for the full rationale.
    RTXDI_Reservoir outlierState = RTXDI_EmptyReservoir();
    RTXDI_SampleRandomLights(state, outlierState, rng, surface, previousBestLightIndex, previousBestLightPortalIdx,
      cb.enableRtxdiInitialVisibility && !RTXDI_DEFER_INITIAL_VISIBILITY);

    // Best-light reuse: a single light reservoir sampled from the previous
    // frame's neighbourhood winner. Combined into `state` (main) — if the
    // best light is itself an outlier (e.g. the distant light), it would
    // already have appeared in the per-type random sampling above and been
    // routed to outlierState; merging here into main is intentional so the
    // best-light contribution influences the budget-clamp ratio rather than
    // bypassing it.
    RTXDI_Reservoir bestLightReservoir = RTXDI_SampleSingleLight(rng, surface, previousBestLightIndex, previousBestLightPortalIdx,
      cb.enableRtxdiInitialVisibility && !RTXDI_DEFER_INITIAL_VISIBILITY);
    float random = RAB_GetNextRandom(rng);
    RTXDI_CombineReservoirs(state, bestLightReservoir, random, bestLightReservoir.targetPdf);

    // MegaLights outlier-budget clamp. Cap outlierState.weightSum to a
    // fraction of state.weightSum, so the post-merge weightSum is bounded
    // by ~(1 + cap) * state.weightSum regardless of how large the outlier
    // targetPdf is. cap=0.33 yields ≤25% post-merge contribution from
    // outliers, matching Epic's MegaLights 20-25% directional-light cap.
    // Gated by cb.enableRtxdiOutlierBudgetClamp so the previous behaviour
    // (no clamp) can be restored for A/B comparison.
    if (cb.enableRtxdiOutlierBudgetClamp)
    {
      outlierState.weightSum = min(outlierState.weightSum,
                                   cb.rtxdiOutlierWeightCap * state.weightSum);
    }
    const float outlierMergeRnd = RAB_GetNextRandom(rng);
    RTXDI_CombineReservoirs(state, outlierState, outlierMergeRnd, outlierState.targetPdf);

#if RTXDI_DEFER_INITIAL_VISIBILITY
    if (cb.enableRtxdiInitialVisibility)
    {
      RTXDI_UpdateSelectedReservoirVisibility(state, surface);
    }
#endif

    // Master-state finalization: the per-type localStates inside
    // RTXDI_SampleRandomLights are individually finalized, but the
    // cross-type-combined master state is not. Without finalization,
    // state.weightSum stays as a raw accumulator instead of the unbiased
    // contribution weight (W_R) form the integrator expects when reading
    // reservoir.weightSum as inverseSelectionPdf at lighting.slangh:63.
    // Calling finalize here matches the SDK pattern. Gated behind
    // cb.enableRtxdiMasterReservoirFinalize so users can A/B compare.
    if (cb.enableRtxdiMasterReservoirFinalize)
    {
      RTXDI_FinalizeResampling(state, 1.0, state.M);
    }

    // Normalize M to 1 so downstream temporal reuse treats this initial
    // reservoir as a single accumulated sample rather than as a multi-sample
    // history. Historically this was set unconditionally with the comment
    // "I have NO IDEA why this works" — the rationale is that initial
    // sampling produces one effective sample per pixel, and temporal reuse
    // uses M as a history-length counter.
    state.M = 1;
  }

  RAB_StoreReservoir(state, pixelCoordinate, RTXDI_GetTemporalOutputPage());
}
