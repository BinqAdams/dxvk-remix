/*
 * Copyright (c) 2022-2023, NVIDIA CORPORATION. All rights reserved.
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
#include "pch.h"
#include "d3d9_lss.h"


/*
 * Direct3DStateBlock9_LSS Interface Implementation
 */

// [PK-DIAG] Defensive wrapper for the D3DAutoPtr-holding slot copies in
// StateTransfer. Matches the UAF-skip patch at base.h:213 (`decRef` empty
// `m_deleter`), but handles the case where the freed object's page has been
// unmapped (e.g. after two back-to-back World::Release events on a PainKiller
// level change). When that happens, even the empty-deleter guard can't run —
// the first dereference in D3DAutoPtr::reset() → incRef() AVs at
// `mov ecx, [eax+8]` (m_fusedRefCnt).
//
// MSVC won't let us put __try in a function that needs C++ unwinding. Each
// AutoPtr assignment ends up inlining operator= + temporaries → the helper
// frame would require unwinding → C2712. Fix: make each copy a noinline
// member function so the SEH wrapper's own body only contains flag tests,
// for-loops over ints, and plain function calls — no local unwind deps.

void Direct3DStateBlock9_LSS::pk_copy_indices(BaseDirect3DDevice9Ex_LSS::State& src,
                                              BaseDirect3DDevice9Ex_LSS::State& dst) {
  dst.indices = src.indices;
}
void Direct3DStateBlock9_LSS::pk_copy_stream(BaseDirect3DDevice9Ex_LSS::State& src,
                                             BaseDirect3DDevice9Ex_LSS::State& dst, int i) {
  dst.streams[i] = src.streams[i];
}
void Direct3DStateBlock9_LSS::pk_copy_texture(BaseDirect3DDevice9Ex_LSS::State& src,
                                              BaseDirect3DDevice9Ex_LSS::State& dst, int i) {
  dst.textures[i] = src.textures[i];
  dst.textureTypes[i] = src.textureTypes[i];
}
void Direct3DStateBlock9_LSS::pk_copy_vertex_shader(BaseDirect3DDevice9Ex_LSS::State& src,
                                                    BaseDirect3DDevice9Ex_LSS::State& dst) {
  dst.vertexShader = src.vertexShader;
}
void Direct3DStateBlock9_LSS::pk_copy_pixel_shader(BaseDirect3DDevice9Ex_LSS::State& src,
                                                   BaseDirect3DDevice9Ex_LSS::State& dst) {
  dst.pixelShader = src.pixelShader;
}

// IMPORTANT: no C++ objects with destructors in this function body. The
// logging (which implicitly creates a std::string temporary because
// Logger::err takes `const std::string&`) must live in the CALLER, not
// here — otherwise MSVC fires C2712 on __try with unwinding.
bool Direct3DStateBlock9_LSS::StateTransfer_CopyAutoptrSlots_SEH(
    const BaseDirect3DDevice9Ex_LSS::StateCaptureDirtyFlags& flags,
    BaseDirect3DDevice9Ex_LSS::State& src,
    BaseDirect3DDevice9Ex_LSS::State& dst) {
  __try {
    if (flags.indices) {
      pk_copy_indices(src, dst);
    }
    for (int i = 0; i < (int) flags.streams.size(); i++) {
      if (flags.streams[i]) {
        pk_copy_stream(src, dst, i);
      }
    }
    for (int i = 0; i < (int) flags.textures.size(); i++) {
      if (flags.textures[i]) {
        pk_copy_texture(src, dst, i);
      }
    }
    if (flags.vertexShader) {
      pk_copy_vertex_shader(src, dst);
    }
    if (flags.pixelShader) {
      pk_copy_pixel_shader(src, dst);
    }
    return true;
  } __except (GetExceptionCode() == EXCEPTION_ACCESS_VIOLATION
              ? EXCEPTION_EXECUTE_HANDLER : EXCEPTION_CONTINUE_SEARCH) {
    return false;
  }
}

HRESULT Direct3DStateBlock9_LSS::QueryInterface(REFIID riid, LPVOID* ppvObj) {
  LogFunctionCall();
  if (ppvObj == nullptr)
    return E_POINTER;

  *ppvObj = nullptr;

  if (riid == __uuidof(IUnknown)
    || riid == __uuidof(IDirect3DStateBlock9)) {
    *ppvObj = bridge_cast<IDirect3DStateBlock9*>(this);
    AddRef();
    return S_OK;
  }

  return E_NOINTERFACE;
}

ULONG Direct3DStateBlock9_LSS::AddRef() {
  LogFunctionCall();
  // No push since we only care about the last Release call
  return D3DBase::AddRef();
}

ULONG Direct3DStateBlock9_LSS::Release() {
  LogFunctionCall();
  return D3DBase::Release();
}

void Direct3DStateBlock9_LSS::onDestroy() {
  ClientMessage { Commands::IDirect3DStateBlock9_Destroy, getId() };
}

HRESULT Direct3DStateBlock9_LSS::GetDevice(IDirect3DDevice9** ppDevice) {
  LogFunctionCall();
  if (ppDevice == nullptr) {
    return D3DERR_INVALIDCALL;
  }
  m_pDevice->AddRef();
  (*ppDevice) = m_pDevice;
  return S_OK;
}

void Direct3DStateBlock9_LSS::StateTransfer(const BaseDirect3DDevice9Ex_LSS::StateCaptureDirtyFlags& flags, BaseDirect3DDevice9Ex_LSS::State& src, BaseDirect3DDevice9Ex_LSS::State& dst) {
  for (size_t i = 0; i < dst.renderStates.size(); i++) {
    if (flags.renderStates[i]) {
      dst.renderStates[i] = src.renderStates[i];
    }
  }
  if (flags.vertexDecl) {
    dst.vertexDecl = src.vertexDecl;
  }
  // [PK-DIAG] D3DAutoPtr-holding slot copies (indices, streams[], textures[],
  // vertexShader, pixelShader) fault on an unmapped freed-object page when
  // the Ref::Both UAF fires and the OS has already reclaimed the page —
  // see helper above. Non-refcounted blocks below stay outside the guard.
  if (!StateTransfer_CopyAutoptrSlots_SEH(flags, src, dst)) {
    static thread_local uint32_t s_pkDiagHits = 0;
    if (s_pkDiagHits < 16) {
      bridge_util::Logger::err(
          "[PK-DIAG] StateTransfer: AV during autoptr copy - skipping"
          " remainder (use-after-free/unmapped page; Ref::Both UAF, likely"
          " post level-change)");
      ++s_pkDiagHits;
      if (s_pkDiagHits == 16) {
        bridge_util::Logger::err(
            "[PK-DIAG] StateTransfer AV: further hits silenced on this"
            " thread");
      }
    }
  }
  for (int i = 0; i < flags.samplerStates.size(); i++) {
    for (int j = 0; j < flags.samplerStates[i].size(); j++) {
      if (flags.samplerStates[i][j]) {
        dst.samplerStates[i][j] = src.samplerStates[i][j];
      }
    }
  }
  for (int i = 0; i < flags.streamOffsetsAndStrides.size(); i++) {
    if (flags.streamOffsetsAndStrides[i]) {
      dst.streamOffsets[i] = src.streamOffsets[i];
      dst.streamStrides[i] = src.streamStrides[i];
    }
  }
  for (int i = 0; i < flags.streamFreqs.size(); i++) {
    if (flags.streamFreqs[i]) {
      dst.streamFreqs[i] = src.streamFreqs[i];
    }
  }
  if (flags.material) {
    dst.material = src.material;
  }
  for (const auto& [key, value] : flags.lights) {
    dst.lights[key] = src.lights[key];
  }
  for (const auto& [key, value] : flags.bLightEnables) {
    dst.bLightEnables[key] = src.bLightEnables[key];
  }
  for (int i = 0; i < flags.transforms.size(); i++) {
    if (flags.transforms[i]) {
      dst.transforms[i] = src.transforms[i];
    }
  }
  for (int i = 0; i < flags.textureStageStates.size(); i++) {
    for (int j = 0; j < flags.textureStageStates[i].size(); j++) {
      if (flags.textureStageStates[i][j]) {
        dst.textureStageStates[i][j] = src.textureStageStates[i][j];
      }
    }
  }
  if (flags.viewport) {
    dst.viewport = src.viewport;
  }
  if (flags.scissorRect) {
    dst.scissorRect = src.scissorRect;
  }
  for (int i = 0; i < flags.clipPlanes.size(); i++) {
    if (flags.clipPlanes[i]) {
      for (int j = 0; j < 4; j++) {
        dst.clipPlanes[i][j] = src.clipPlanes[i][j];
      }
    }
  }
  for (int i = 0; i < flags.vertexConstants.fConsts.size(); i++) {
    if (flags.vertexConstants.fConsts[i]) {
      dst.vertexConstants.fConsts[i] = src.vertexConstants.fConsts[i];
    }
  }
  for (int i = 0; i < flags.vertexConstants.iConsts.size(); i++) {
    if (flags.vertexConstants.iConsts[i]) {
      dst.vertexConstants.iConsts[i] = src.vertexConstants.iConsts[i];
    }
  }
  for (int i = 0; i < flags.vertexConstants.bConsts.size(); i++) {
    if (flags.vertexConstants.bConsts[i]) {
      size_t dwordIndex = i / 32;
      size_t dwordOffset = i % 32;
      uint32_t bitMask = 1 << dwordOffset;
      dst.vertexConstants.bConsts[dwordIndex]
        = (src.vertexConstants.bConsts[dwordIndex] & bitMask) ? dst.vertexConstants.bConsts[dwordIndex] | bitMask : dst.vertexConstants.bConsts[dwordIndex] & ~bitMask;
    }
  }
  for (int i = 0; i < flags.pixelConstants.fConsts.size(); i++) {
    if (flags.pixelConstants.fConsts[i]) {
      dst.pixelConstants.fConsts[i] = src.pixelConstants.fConsts[i];
    }
  }
  for (int i = 0; i < flags.pixelConstants.iConsts.size(); i++) {
    if (flags.pixelConstants.iConsts[i]) {
      dst.pixelConstants.iConsts[i] = src.pixelConstants.iConsts[i];
    }
  }
  for (int i = 0; i < flags.pixelConstants.bConsts.size(); i++) {
    if (flags.pixelConstants.bConsts[i]) {
      size_t dwordIndex = i / 32;
      size_t dwordOffset = i % 32;
      uint32_t bitMask = 1 << dwordOffset;
      dst.pixelConstants.bConsts[dwordIndex]
        = (src.pixelConstants.bConsts[dwordIndex] & bitMask) ? dst.pixelConstants.bConsts[dwordIndex] | bitMask : dst.pixelConstants.bConsts[dwordIndex] & ~bitMask;
    }
  }
}

void Direct3DStateBlock9_LSS::LocalCapture() {
  StateTransfer(m_dirtyFlags, m_pDevice->m_state, m_captureState);
}

HRESULT Direct3DStateBlock9_LSS::Capture() {
  LogFunctionCall();
  if (m_pDevice->m_stateRecording) {
    return D3DERR_INVALIDCALL;
  }
  LocalCapture();
  {
    ClientMessage { Commands::IDirect3DStateBlock9_Capture, getId() };
  }
  return S_OK;
}

HRESULT Direct3DStateBlock9_LSS::Apply() {
  LogFunctionCall();
  StateTransfer(m_dirtyFlags, m_captureState, m_pDevice->m_state);
  {
    ClientMessage { Commands::IDirect3DStateBlock9_Apply, getId() };
  }
  return S_OK;
}
