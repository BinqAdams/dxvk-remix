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

//!variant rtxdi_spatial_reuse.comp
//!>       RTXDI_NO_PORTALS=0
//!>       RTXDI_ENABLE_BSDF_DETAIL=1

//!variant rtxdi_spatial_reuse_no_portals.comp
//!>       RTXDI_NO_PORTALS=1
//!>       RTXDI_ENABLE_BSDF_DETAIL=1

//!variant rtxdi_spatial_reuse_no_bsdf_detail.comp
//!>       RTXDI_NO_PORTALS=0
//!>       RTXDI_ENABLE_BSDF_DETAIL=0

//!variant rtxdi_spatial_reuse_no_portals_no_bsdf_detail.comp
//!>       RTXDI_NO_PORTALS=1
//!>       RTXDI_ENABLE_BSDF_DETAIL=0

//!end-variants

#define USE_32BIT_RAY_DIRECTION 1
#define RAB_HAS_CURRENT_GBUFFER 1
#define SHADOW_TERMINATOR_FIX_ALLOWED 1
#define RAB_HAS_RTXDI_RESERVOIRS 1
#define RTXDI_COHERENT_SPATIAL_NEIGHBOR_OFFSETS 1

#ifndef RTXDI_ENABLE_BSDF_DETAIL
#define RTXDI_ENABLE_BSDF_DETAIL 1
#endif

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
#include "rtx/algorithm/visibility.slangh"
#include "rtx/algorithm/rtxdi/rtxdi.slangh"
#if RTXDI_ENABLE_BSDF_DETAIL
#include "rtxdi/DlssEnhancementFilterFunctions.slangh"
#endif
#include "rtx/pass/sparse_rendering/compact_active_pixels.slangh"

// Reservoir boiling filter: detects per-pixel reservoirs whose targetPdf
// (light-sample weight) is a large multiple of the local block average,
// and zeros their M so the next temporal pass resamples instead of locking
// the outlier in. Mirrors the per-luminance filter that ReSTIR GI runs in
// restir_gi_final_shading.comp.slang, but operates pre-shading on the
// RTXDI reservoir's own weight.
//
// Threadgroup is 16x8 = 128 lanes (vs ReSTIR GI's 8x8 = 64), so the
// groupshared aggregation arrays are sized for 128 / minLaneCount waves.
#define RTXDI_BOILING_FILTER_MIN_LANE_COUNT 32
#define RTXDI_BOILING_FILTER_GROUP_SIZE_X 16
#define RTXDI_BOILING_FILTER_GROUP_SIZE_Y 8
#define RTXDI_BOILING_FILTER_GROUP_SIZE (RTXDI_BOILING_FILTER_GROUP_SIZE_X * RTXDI_BOILING_FILTER_GROUP_SIZE_Y)
#define RTXDI_BOILING_FILTER_WAVE_SLOTS ((RTXDI_BOILING_FILTER_GROUP_SIZE + RTXDI_BOILING_FILTER_MIN_LANE_COUNT - 1) / RTXDI_BOILING_FILTER_MIN_LANE_COUNT)

groupshared float s_rtxdiBoilingWeights[RTXDI_BOILING_FILTER_WAVE_SLOTS];
groupshared uint  s_rtxdiBoilingCount[RTXDI_BOILING_FILTER_WAVE_SLOTS];

// Returns true if `reservoir` was identified as an outlier and zeroed.
bool applyRtxdiReservoirBoilingFilter(uint2 LocalIndex, inout RTXDI_Reservoir reservoir)
{
  // Per-pixel weight: use targetPdf for valid reservoirs only. Invalid
  // (empty) reservoirs contribute zero weight and zero count so they do
  // not pull the average down.
  const bool valid = RTXDI_IsValidReservoir(reservoir);
  float weight = valid ? reservoir.targetPdf : 0.0f;

  // Wave-level reduction (lanes within the same SIMD wave).
  float waveWeight = WaveActiveSum(weight);
  uint  waveCount  = WaveActiveCountBits(weight > 0.0f);

  const uint linearThreadIndex = LocalIndex.x + LocalIndex.y * RTXDI_BOILING_FILTER_GROUP_SIZE_X;
  const uint waveIndex = linearThreadIndex / WaveGetLaneCount();

  if (WaveIsFirstLane())
  {
    s_rtxdiBoilingWeights[waveIndex] = waveWeight;
    s_rtxdiBoilingCount[waveIndex]   = waveCount;
  }

  GroupMemoryBarrierWithGroupSync();

  // One wave reduces all per-wave partials into a single average.
  const uint numWaves = (RTXDI_BOILING_FILTER_GROUP_SIZE + WaveGetLaneCount() - 1) / WaveGetLaneCount();
  if (linearThreadIndex < numWaves)
  {
    waveWeight = s_rtxdiBoilingWeights[linearThreadIndex];
    waveCount  = s_rtxdiBoilingCount[linearThreadIndex];

    waveWeight = WaveActiveSum(waveWeight);
    waveCount  = WaveActiveSum(waveCount);

    if (linearThreadIndex == 0)
    {
      s_rtxdiBoilingWeights[0] = (waveCount > 0) ? (waveWeight / float(waveCount)) : 0.0f;
    }
  }

  GroupMemoryBarrierWithGroupSync();

  const float averageNonzeroWeight = s_rtxdiBoilingWeights[0];

  // Only filter once the reservoir has had time to accumulate -- otherwise
  // we punish freshly-disoccluded pixels for being legitimately bright.
  if (valid &&
      reservoir.M >= cb.rtxdiMaxHistoryLength &&
      averageNonzeroWeight > 0.0f &&
      reservoir.targetPdf > averageNonzeroWeight * cb.rtxdiReservoirBoilingFilterThreshold)
  {
    reservoir = RTXDI_EmptyReservoir();
    return true;
  }
  return false;
}

[shader("compute")]
[numthreads(16, 8, 1)]
void main(int2 threadIndex : SV_DispatchThreadID, uint2 LocalIndex : SV_GroupThreadID)
{
  // Out-of-bounds threads exit early. Inactive (sparse-skipped) and
  // invalid-surface threads keep going with an empty reservoir so they
  // can participate in the boiling-filter barrier; they bail out after
  // the filter call.
  if (any(threadIndex >= cb.camera.resolution))
  {
    return;
  }

  uvec2 remapped;
  const bool isActive = loadPixelCoordinate(uint2(threadIndex), DirectActiveLocalPixelCoords,
    cb.camera.resolution, cb.sparseRenderingArgs, remapped);
  int2 pixelCoordinate = int2(remapped);

  RAB_Surface surface = RAB_GetGBufferSurface(pixelCoordinate, false);

  // Only write GBufferLast for active pixels here; inactive pixels write it
  // below after the boiling-filter barrier, if pass-through is enabled.
  if (isActive && !cb.enableReSTIRGI)
  {
    imageStore(GBufferLast, pixelCoordinate, RAB_PackLastFrameGBuffer(surface));
  }

  // surfaceValid is always false for inactive pixels so they skip spatial
  // resampling but still reach the boiling-filter barrier with an empty reservoir.
  const bool surfaceValid = isActive && RAB_IsSurfaceValid(surface);

  RTXDI_Reservoir result = RTXDI_EmptyReservoir();

  if (surfaceValid)
  {
    RAB_RandomSamplerState rtxdiRNG = RAB_InitRandomSampler(pixelCoordinate, cb.frameIdx, 3);

    RTXDI_Reservoir reservoir = RAB_LoadReservoir(pixelCoordinate, RTXDI_GetSpatialInputPage());

    // Calculate the average reprojection confidence in the neighborhood to reject individual pixels that failed to reproject
    const int filterRadius = 1;
    const int filterArea = (filterRadius * 2 + 1) * (filterRadius * 2 + 1);
    float sumConfidence = 0;
    for (int xx = -filterRadius; xx <= filterRadius; ++xx)
    for (int yy = -filterRadius; yy <= filterRadius; ++yy)
    {
      sumConfidence += ReprojectionConfidence[pixelCoordinate + int2(xx, yy)].r;
    }

    const float historyLength = sumConfidence * (float(kReprojectionConfidenceHistoryLength) / float(filterArea));

    // Use the average history length to decide if we need to apply disocclusion boost.
    int numSpatialSamples = historyLength < cb.rtxdiDisocclusionFrames
      ? cb.rtxdiDisocclusionSamples
      : cb.rtxdiSpatialSamples;

    RTXDI_SpatialResamplingParameters sparams;
    sparams.numSamples = cb.enableRtxdiSpatialReuse ? clamp(numSpatialSamples, 1, 16) : 0;
    sparams.sourceBufferIndex = RTXDI_GetSpatialInputPage();
    sparams.biasCorrectionMode = cb.enableRtxdiRayTracedBiasCorrection
      ? RTXDI_BIAS_CORRECTION_RAY_TRACED
      : RTXDI_BIAS_CORRECTION_BASIC;
    sparams.samplingRadius = 30;
    sparams.normalThreshold = 0.5;
    sparams.depthThreshold = 0.1;
    sparams.screenResolution = cb.camera.resolution;

    result = RTXDI_SpatialResampling(
      pixelCoordinate,
      surface,
      reservoir,
      rtxdiRNG,
      sparams);
  }

  // Boiling filter -- run for ALL in-bounds threads including inactive and
  // invalid-surface ones, so every thread in a full group reaches both
  // GroupMemoryBarrierWithGroupSync calls. Those threads contribute an empty
  // reservoir (weight=0, count=0) which does not skew the group average.
  // Skip partial threadgroups at the screen edge.
  const uint2 groupCornerThreadID = uint2(threadIndex) - LocalIndex;
  const uint2 groupSize = uint2(RTXDI_BOILING_FILTER_GROUP_SIZE_X, RTXDI_BOILING_FILTER_GROUP_SIZE_Y);
  if (cb.enableRtxdiReservoirBoilingFilter &&
      all(groupCornerThreadID + groupSize - 1 < uint2(cb.camera.resolution)))
  {
    applyRtxdiReservoirBoilingFilter(LocalIndex, result);
  }

  // Inactive-pixel pass-through: deferred until after the boiling-filter
  // barrier so inactive threads don't leave active threads stuck at the barrier.
  if (!isActive)
  {
    if (cb.sparseRenderingArgs.enableRtxdiReuseForInactivePixels)
    {
      if (!cb.enableReSTIRGI) {
        imageStore(GBufferLast, pixelCoordinate, RAB_PackLastFrameGBuffer(surface));
      }

      // Pass through the reservoir from temporal reuse unchanged
      RTXDI_Reservoir reservoir = RAB_LoadReservoir(pixelCoordinate, RTXDI_GetSpatialInputPage());
      RAB_StoreReservoir(reservoir, pixelCoordinate, RTXDI_GetSpatialOutputPage());

      // Neutral BSDF factor for inactive pixels
      BSDFFactor[pixelCoordinate] = vec2(1);
    }
    return;
  }

  if (!surfaceValid)
  {
    return;
  }

  RAB_StoreReservoir(result, pixelCoordinate, RTXDI_GetSpatialOutputPage());

  vec2 factor = vec2(1);
#if RTXDI_ENABLE_BSDF_DETAIL
  if (cb.enableEnhanceBSDFDetail && RTXDI_IsValidReservoir(result) && cb.enhanceBSDFDirectLightPower > 0)
  {
    const RAB_LightSample finalSample =
      RAB_GetPortalSpaceLightSample(result.lightIdx, vec2(result.uv), result.portalIdx, surface);
    const float3 cameraPosition = cameraGetWorldPosition(cb.camera);
    const float neighborDepthThreshold = 0.02f;
    const float neighborNormalThreshold = 0.998f;
    const float brdfClampMin = 0.001f;
    const float brdfClampMax = 1000.0f;
    float3 finalSampleDirection = normalize(finalSample.position - surface.minimalSurfaceInteraction.position);
    factor = RTXDI_GetDlssEnhancementDirectFactor(pixelCoordinate, finalSample.position, finalSampleDirection, false, cameraPosition, neighborDepthThreshold, neighborNormalThreshold, brdfClampMin, brdfClampMax);

    factor = pow(factor, cb.enhanceBSDFDirectLightPower);
    factor = clamp(factor, vec2(0), vec2(cb.enhanceBSDFDirectLightMaxValue));
  }
#endif
  BSDFFactor[pixelCoordinate] = vec2(factor);
}
