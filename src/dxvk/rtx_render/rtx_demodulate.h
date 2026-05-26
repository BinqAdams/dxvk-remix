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
#pragma once

#include "../dxvk_format.h"
#include "../dxvk_include.h"

#include "../spirv/spirv_code_buffer.h"
#include "rtx_resources.h"
#include "rtx_option.h"

namespace dxvk {

  class RtxContext;

  class DemodulatePass {

  public:

    DemodulatePass(dxvk::DxvkDevice* device);
    ~DemodulatePass();

    void dispatch(
      RtxContext* ctx, 
      const Resources::RaytracingOutput& rtOutput);

    void showImguiSettings();

    RTX_OPTION("rtx.demodulate", bool, demodulateRoughness, true, "Demodulate roughness to improve specular details.");
    RTX_OPTION("rtx.demodulate", float, demodulateRoughnessOffset, 0.1f, "Strength of roughness demodulation, lower values are stronger.");
    RTX_OPTION_ARGS("rtx.demodulate", bool, enableDirectLightBoilingFilter, true, "Boiling filter removing direct light sample when its luminance is too high.",
                    args.flags = RtxOptionFlags::UserSetting);
    RTX_OPTION("rtx.demodulate", float, directLightBoilingThreshold, 5.f, "Remove direct light sample when its luminance is higher than the average one multiplied by this threshold .");
    // Demodulation mode. Must match kDemodulationMode* constants in rtx/utility/demodulate_helpers.slangh.
    //   0 = Default per-channel max(albedo, albedoLowerBound)
    //   1 = LuminanceFloor: chroma-preserving floor on albedo luminance, applied symmetrically
    //       in demodulator (as divisor) and composite (as re-modulator). Avoids the dim-output
    //       artifact mode 0 produces when albedoLowerBound is raised, and gives the denoiser
    //       bounded-magnitude input without lying to the composite step about the albedo used.
    RTX_OPTION_ARGS("rtx.demodulate", uint32_t, mode, 0,
                    "Demodulation mode. 0 = per-channel albedo clamp (default; matches historical behaviour). 1 = luminance-aware symmetric albedo flooring (uses albedoLuminanceFloor; mid-dark surfaces are lifted to that luminance in BOTH demod and composite, so the denoiser sees bounded magnitudes and the output is consistent).",
                    args.flags = RtxOptionFlags::UserSetting);
    RTX_OPTION_ARGS("rtx.demodulate", float, albedoLowerBound, 0.01f,
                    "Mode 0 only. Lower bound applied per-channel to the albedo divisor in the demodulator (light / max(albedo, bound)). "
                    "Default 0.01 matches historical behavior. Higher values dim low-albedo final output (asymmetric remod).",
                    args.flags = RtxOptionFlags::UserSetting);
    RTX_OPTION_ARGS("rtx.demodulate", float, albedoLuminanceFloor, 0.05f,
                    "Mode 1 only. Minimum BT.709 luminance the effective albedo is allowed to reach. Below this floor the albedo is scaled up (preserving chromaticity) to match the floor luminance. "
                    "Used symmetrically by the demodulator and composite pass so the final output is reversible. "
                    "Higher values dampen noise amplification on dark surfaces; very-dark surfaces appear slightly brighter than physically correct as a trade-off. 0.02-0.1 is the practical tuning range.",
                    args.flags = RtxOptionFlags::UserSetting);

  private:
    Rc<vk::DeviceFn> m_vkd;

    dxvk::DxvkDevice* m_device;
  };
} // namespace dxvk
