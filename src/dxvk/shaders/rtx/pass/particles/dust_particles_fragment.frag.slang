/*
* Copyright (c) 2022-2025, NVIDIA CORPORATION. All rights reserved.
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
#include "rtx/pass/common_bindings.slangh"
#include "rtx/pass/particles/dust_particles_bindings.slangh"

#include "rtx/utility/common.slangh"
#include "rtx/utility/noise.slangh"
#include "rtx/utility/brdf.slangh"
#include "rtx/utility/froxel.slangh"
#include "rtx/utility/packing.slangh"
#include "rtx/concept/camera/camera.slangh"

float softEdge(float size, float2 centerUv, float2 screenUv)
{
  float2 uvSize = size.xx * 0.5f / particleCb.renderResolution;
  return pow(1.f - saturate(length((screenUv - centerUv) / uvSize)), 1.f/3);
}

[shader("fragment")]
float4 main(float4 screenPos : SV_Position, float4 radiance : COLOR, nointerpolation float3 centerPosSize : CENTER) : SV_Target
{
  // depth test
  const float2 screenUV = screenPos.xy / particleCb.renderResolution;

  const float depth = PrimaryDepth.SampleLevel(screenUV, 0);

  // W23: skip dust on viewmodel pixels. rtx.viewModel.scale's view-space-Z
  // scaling pushes viewmodel depth toward the far plane in PrimaryDepth,
  // so the regular `depth <= screenPos.z` test never discards dust on top
  // of the gun (at small viewmodel scales the entire weapon gets covered
  // by atmospheric dust). The viewmodel is conceptually a HUD overlay —
  // atmospheric particles should never appear in front of it regardless
  // of its "true" depth. Bit 0 of PrimarySurfaceFlags is `isViewModel`
  // per post_fx_motion_blur_geometry_flags.slangh's encoder.
  // Use explicit dimension query because PrimarySurfaceFlags may be at
  // render resolution (pre-upscale) while screenPos.xy is at output
  // resolution (post-upscale).
  uint2 sfDim;
  PrimarySurfaceFlags.GetDimensions(sfDim.x, sfDim.y);
  const int2 sfPixel = int2(clamp(screenUV * float2(sfDim), float2(0.f, 0.f), float2(sfDim) - 1.f));
  const uint flags = PrimarySurfaceFlags[sfPixel];
  const bool isViewModel = (flags & 0x1u) != 0u;

  if (isViewModel || (depth <= screenPos.z && depth > 0.f))
    discard;

  const float blend_range = 0.0005f;
  return radiance * softEdge(centerPosSize.z, centerPosSize.xy, screenUV) * saturate(abs(screenPos.z-depth) / blend_range);
}
