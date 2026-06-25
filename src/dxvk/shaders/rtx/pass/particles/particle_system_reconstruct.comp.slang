/*
* Copyright (c) 2025, NVIDIA CORPORATION. All rights reserved.
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

// Reconstruct one GpuParticle per source billboard quad from a legacy FFP particle
// draw's geometry, so the game's already-simulated particles can render through the
// RtxParticleSystem fast path (single refit BLAS per material). The quads are
// world-space camera-facing billboards; generate_geometry re-billboards them to the
// live camera. Size + colour are carried explicitly per particle (the source quads
// hold the final values), bypassing the descriptor's life-curve LUT.

#include "rtx/pass/particles/particle_system_binding_indices.h"
#include "rtx/pass/particles/particle_system_reconstruct_binding_indices.h"
#include "rtx/utility/packing.slangh"

layout(binding = RECONSTRUCT_PARTICLES_BINDING_POSITION_INPUT)
StructuredBuffer<float> srcPosition;

layout(binding = RECONSTRUCT_PARTICLES_BINDING_TEXCOORD_INPUT)
StructuredBuffer<float> srcTexcoord;

layout(binding = RECONSTRUCT_PARTICLES_BINDING_COLOR_INPUT)
StructuredBuffer<uint32_t> srcColor;

layout(binding = RECONSTRUCT_PARTICLES_BINDING_PARTICLES_OUTPUT)
RWStructuredBuffer<GpuParticle> particlesOut;

layout(push_constant)
ConstantBuffer<ReconstructParticleArgs> cb;

float3 readPosition(uint vtx) {
  const uint base = cb.positionOffset + vtx * cb.positionStride;
  return float3(srcPosition[base + 0], srcPosition[base + 1], srcPosition[base + 2]);
}

float2 readTexcoord(uint vtx) {
  const uint base = cb.texcoordOffset + vtx * cb.texcoordStride;
  return float2(srcTexcoord[base + 0], srcTexcoord[base + 1]);
}

float4 readColor(uint vtx) {
  if (cb.hasColor == 0) {
    return float4(1.0, 1.0, 1.0, 1.0);
  }
  // D3DCOLOR (VK_FORMAT_B8G8R8A8_UNORM): little-endian bytes [B, G, R, A].
  const uint packed = srcColor[cb.colorOffset + vtx * cb.colorStride];
  const float inv = 1.0 / 255.0;
  return float4(
    float((packed >> 16) & 0xFFu) * inv,  // R
    float((packed >>  8) & 0xFFu) * inv,  // G
    float((packed      ) & 0xFFu) * inv,  // B
    float((packed >> 24) & 0xFFu) * inv); // A
}

[shader("compute")]
[numthreads(128, 1, 1)]
void main(uint quad : SV_DispatchThreadID) {
  if (quad >= cb.numQuads) {
    return;
  }

  // Source layout is 4 contiguous vertices per quad (single-quad triangle strip,
  // or indexed quad-list whose vertex buffer is dense 4-verts-per-quad — matching
  // the particle system's own index buffer). 6-vertex trilist quads and
  // vertex-shared beams are filtered out on the CPU side and never reach here.
  const uint v0 = quad * 4;
  const float3 p0 = readPosition(v0 + 0);
  const float3 p1 = readPosition(v0 + 1);
  const float3 p2 = readPosition(v0 + 2);
  const float3 p3 = readPosition(v0 + 3);

  const float3 center = (p0 + p1 + p2 + p3) * 0.25;

  // Recover the quad's two edge lengths without assuming a winding order: of the
  // three distances from p0, the largest is the diagonal; the other two are the
  // width and height.
  const float d1 = length(p1 - p0);
  const float d2 = length(p2 - p0);
  const float d3 = length(p3 - p0);
  float sizeX;
  float sizeY;
  if (d1 >= d2 && d1 >= d3) { sizeX = d2; sizeY = d3; }
  else if (d2 >= d1 && d2 >= d3) { sizeX = d1; sizeY = d3; }
  else { sizeX = d1; sizeY = d2; }

  const float4 rgba = readColor(v0);

  const float2 t0 = readTexcoord(v0 + 0);
  const float2 t1 = readTexcoord(v0 + 1);
  const float2 t2 = readTexcoord(v0 + 2);
  const float2 t3 = readTexcoord(v0 + 3);
  const float2 uvMin = min(min(t0, t1), min(t2, t3));
  const float2 uvMax = max(max(t0, t1), max(t2, t3));

  GpuParticle p;
  p.position = center;
  p.enBaseColor = float4x32ToUnorm4x8(rgba);
  p.velocity = float3(0.0, 0.0, 0.0);
  p.randSeed = 0.0;
  p.uvMinMax = f16vec4(uvMin.x, uvMin.y, uvMax.x, uvMax.y);
  p.rotation = (half)0.0;
  p.timeToLive = (half)1.0;       // alive; minTTL=maxTTL=1 -> normalizedLife = 1
  p.pad0 = (half)sizeX;           // explicit per-particle size (read by generate_geometry)
  p.pad1 = (half)sizeY;

  particlesOut[cb.baseParticleIndex + quad] = p;
}
