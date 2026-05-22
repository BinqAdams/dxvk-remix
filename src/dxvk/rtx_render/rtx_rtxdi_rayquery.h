/*
* Copyright (c) 2023-2026, NVIDIA CORPORATION. All rights reserved.
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
#pragma once

#include "rtx_resources.h"
#include "rtx_options.h"

struct RaytraceArgs;

namespace dxvk {
  class Config;
  class RtxContext;

  class DxvkRtxdiRayQuery {

  public:

    DxvkRtxdiRayQuery(DxvkDevice* device);
    ~DxvkRtxdiRayQuery() = default;

    void dispatch(RtxContext* ctx, const Resources::RaytracingOutput& rtOutput);
    void dispatchGradient(RtxContext* ctx, const Resources::RaytracingOutput& rtOutput);
    void dispatchConfidence(RtxContext* ctx, const Resources::RaytracingOutput& rtOutput);

    void showImguiSettings();
    void setRaytraceArgs(Resources::RaytracingOutput& rtOutput) const;
    bool getEnableDenoiserConfidence(RtxContext& ctx) const;
    // Returns true if denoiser gradient calculation is enabled and actually consumed downstream
    // (NRD primary denoiser or ReSTIR GI lighting validation).
    bool getEnableDenoiserGradient(RtxContext& ctx) const;
    
    RTX_OPTION("rtx.di", bool, enableCrossPortalLight, true, "");
    RTX_OPTION("rtx.di", bool, enableInitialVisibility, true, "Whether to trace a visibility ray for the light sample selected in the initial sampling pass.");
    RTX_OPTION_ARGS("rtx.di", bool, enableBestLightSampling, true, "Whether to include a single best light from the previous frame's pixel neighborhood into initial sampling.",
                    args.flags = RtxOptionFlags::UserSetting);
    RTX_OPTION_ARGS("rtx.di", bool, enableRayTracedBiasCorrection, true, "Whether to use ray traced bias correction in the spatial reuse pass.",
                    args.flags = RtxOptionFlags::UserSetting);
    RTX_OPTION_ARGS("rtx.di", bool, enableSampleStealing, true, "No visibile IQ gains, but exhibits considerable perf drop (8% in integrate pass).",
                    args.flags = RtxOptionFlags::UserSetting);
    RTX_OPTION_ARGS("rtx.di", bool, stealBoundaryPixelSamplesWhenOutsideOfScreen, true, "Steal screen boundary samples when a hit point is outside the screen.",
                    args.flags = RtxOptionFlags::UserSetting);
    RTX_OPTION("rtx.di", bool, enableSpatialReuse, true, "Whether to apply spatial reuse.");
    RTX_OPTION("rtx.di", bool, enableTemporalBiasCorrection, true, "");
    RTX_OPTION("rtx.di", bool, enableTemporalReuse, true, "Whether to apply temporal reuse.");
    RTX_OPTION("rtx.di", bool, enableDiscardInvisibleSamples, true, "Whether to discard reservoirs that are determined to be invisible in final shading.");
    RTX_OPTION("rtx.di", bool, enableDiscardEnlargedPixels, true, "");
    RTX_OPTION_ARGS("rtx.di", bool, enableDenoiserConfidence, true, "",
                    args.flags = RtxOptionFlags::UserSetting);
    RTX_OPTION("rtx.di", bool, enableDenoiserGradient, true, "Enable gradient calculation, which is used by confidence calculation and GI sample validation.");
    RTX_OPTION_ARGS("rtx.di", uint32_t, initialSampleCount, 4, "The number of lights randomly selected from the global pool to consider when selecting a light with RTXDI.",
                    args.flags = RtxOptionFlags::UserSetting);
    RTX_OPTION_ARGS("rtx.di", uint32_t, spatialSamples, 2, "The number of spatial reuse samples in converged areas.",
                    args.flags = RtxOptionFlags::UserSetting);
    RTX_OPTION_ARGS("rtx.di", uint32_t, disocclusionSamples, 4, "The number of spatial reuse samples in disocclusion areas.",
                    args.flags = RtxOptionFlags::UserSetting);
    RTX_OPTION("rtx.di", uint32_t, disocclusionFrames, 8, "");
    RTX_OPTION("rtx.di", uint32_t, gradientFilterPasses, 4, "");
    RTX_OPTION_ARGS("rtx.di", uint32_t, permutationSamplingNthFrame, 0, "Apply permutation sampling when (frameIdx % this == 0), 0 means off.",
                    args.flags = RtxOptionFlags::UserSetting);
    RTX_OPTION("rtx.di", uint32_t, maxHistoryLength, 4, "Maximum age of reservoirs for temporal reuse.");
    RTX_OPTION("rtx.di", float, gradientHitDistanceSensitivity, 10.f, "");
    RTX_OPTION("rtx.di", float, confidenceHistoryLength, 8.f, "");
    RTX_OPTION("rtx.di", float, confidenceGradientPower, 8.f, "");
    RTX_OPTION("rtx.di", float, confidenceGradientScale, 6.f, "");
    RTX_OPTION("rtx.di", float, minimumConfidence, 0.1f, "");
    RTX_OPTION("rtx.di", float, confidenceHitDistanceSensitivity, 300.0f, "");
    // Reservoir-stage boiling filter. Ported from ReSTIR GI's pre-shading
    // applyBoilingFilter: detects per-pixel reservoirs whose targetPdf is a
    // large multiple of the block average and zeros their M so the next
    // temporal pass resamples instead of locking the outlier in. Distinct
    // from rtx.demodulate.enableDirectLightBoilingFilter, which clamps the
    // post-shaded screen-space color.
    RTX_OPTION_ARGS("rtx.di", bool, enableReservoirBoilingFilter, true,
                    "Enables a per-reservoir boiling filter in the RTXDI spatial reuse pass. Detects outlier reservoirs (M >= rtx.di.maxHistoryLength and targetPdf > average * threshold) and zeros them so the next temporal pass resamples.",
                    args.flags = RtxOptionFlags::UserSetting);
    RTX_OPTION_ARGS("rtx.di", float, reservoirBoilingFilterThreshold, 30.0f,
                    "Multiplier above local block average targetPdf at which a reservoir is considered a boiling outlier and zeroed. Lower values filter more aggressively. Matches rtx.restirGI.boilingFilterRemoveReservoirThreshold semantics on the DI side.",
                    args.flags = RtxOptionFlags::UserSetting);
    // Master-state finalization. RTXDI_SampleRandomLights finalizes each
    // per-type localState before combining into the master state, but the
    // master state itself is not finalized. Without finalize, state.weightSum
    // stays as a raw accumulator instead of the unbiased contribution weight
    // (W_R) the integrator expects when reading it as invSelectionPdf at
    // lighting.slangh:63. Default false to preserve historical brightness
    // tuning (artists tuned to the un-finalized state); enable for the
    // mathematically-correct W_R form.
    RTX_OPTION_ARGS("rtx.di", bool, enableMasterReservoirFinalize, false,
                    "Calls RTXDI_FinalizeResampling on the master initial-sampling reservoir, normalizing state.weightSum to the unbiased contribution weight (W_R) form that the integrator expects. Default false to preserve historical brightness; enable for mathematically-correct W_R semantics.",
                    args.flags = RtxOptionFlags::UserSetting);
    // MegaLights-style outlier-budget clamp (Narkowicz & Costa, SIGGRAPH
    // 2025). The standard ReSTIR DI target PDF is visibility-blind: an
    // occluded high-targetPdf candidate (distant lights amplified by
    // 1/sin^2(half_angle), or bright far spheres) inflates master.weightSum
    // even when V=0 at the current pixel, because the same inflated
    // weightSum is read as inverseSelectionPdf at every pixel where ANOTHER
    // sample wins. Visible as per-pixel sparkles on sphere-lit indoor
    // surfaces that should be unaffected by the distant light.
    //
    // Fix: partition per-pixel RIS candidates into a main reservoir and an
    // outlier reservoir (distant lights + lights with intensity above a
    // per-frame percentile threshold), then clamp the outlier reservoir's
    // weightSum to outlierWeightCap × main.weightSum BEFORE the final
    // merge. The post-merge weightSum is mathematically bounded by
    // (1 + outlierWeightCap) × main.weightSum regardless of how large the
    // outlier's targetPdf is. See D:/VRE3/Docs/RTXDIResearch.md for full
    // SOTA write-up.
    RTX_OPTION_ARGS("rtx.di", bool, enableOutlierBudgetClamp, true,
                    "Partition per-pixel RIS candidates into a main reservoir and an outlier reservoir (distant lights + intensity-percentile outliers), then clamp the outlier weightSum to outlierWeightCap × main.weightSum before merge. Mathematically bounds the master weightSum regardless of outlier targetPdf magnitude, eliminating the visibility-blind RIS inflation that causes per-pixel sparkles on sphere-lit surfaces. Default true.",
                    args.flags = RtxOptionFlags::UserSetting);
    RTX_OPTION_ARGS("rtx.di", float, outlierWeightCap, 0.33f,
                    "Cap ratio for outlier-reservoir weightSum: outlier.weightSum ≤ outlierWeightCap × main.weightSum. 0.33 yields a ~25% post-merge contribution from outliers, matching MegaLights' 20-25% directional-light cap. Lower values clamp more aggressively (darker outdoors when the distant is the dominant light); higher values let outliers through more freely (more residual sparkle indoors).",
                    args.flags = RtxOptionFlags::UserSetting);
    RTX_OPTION_ARGS("rtx.di", float, outlierIntensityPercentile, 99.0f,
                    "Per-frame percentile of non-distant light luminance used as the outlier-classification threshold. 99 → top 1% brightest lights are outliers. Distant lights are ALWAYS outliers regardless of this setting.",
                    args.flags = RtxOptionFlags::UserSetting);
  };
}
