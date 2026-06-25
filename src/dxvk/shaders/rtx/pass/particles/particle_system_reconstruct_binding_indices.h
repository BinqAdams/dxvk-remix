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
#pragma once

// Push-constant arguments + bindings for particle_system_reconstruct.comp.slang.
//
// The reconstruct pass turns a legacy FFP billboard-particle draw (XYZ position,
// D3DCOLOR diffuse, FLOAT2 texcoord — the verified PK FVF XYZ|DIFFUSE|TEX1 signature)
// into one GpuParticle record per source quad (4 contiguous vertices), so the
// already-simulated game particles render through the batched single-refit-BLAS
// particle pipeline. One dispatch per source draw; records are appended into the
// per-material particle state buffer starting at baseParticleIndex.
//
// Offsets/strides are in 32-bit-element units (byte offset / 4), matching the
// StructuredBuffer<float>/<uint32_t> views — identical convention to
// InterleaveGeometryArgs. Source positions are assumed world-space (the PK particle
// draws use D3DTS_WORLD = identity, verified from the capture trace).
struct ReconstructParticleArgs {
  uint positionOffset;
  uint positionStride;
  uint texcoordOffset;
  uint texcoordStride;
  uint colorOffset;
  uint colorStride;
  uint hasColor;
  uint numQuads;
  uint baseParticleIndex;
  uint pad0;
  uint pad1;
  uint pad2;
};

// Binding slots are deliberately high (70+) so this pass can be dispatched on the
// same context as the particle simulate()/generate_geometry passes without clobbering
// their COMMON_RAYTRACING_BINDINGS (slots 0-49) or particle bindings (50-62).
#define RECONSTRUCT_PARTICLES_BINDING_POSITION_INPUT   70
#define RECONSTRUCT_PARTICLES_BINDING_TEXCOORD_INPUT   71
#define RECONSTRUCT_PARTICLES_BINDING_COLOR_INPUT      72
#define RECONSTRUCT_PARTICLES_BINDING_PARTICLES_OUTPUT 73
