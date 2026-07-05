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
#include "rtx_draw_call_cache.h"
#include "rtx_options.h"
#include "../d3d9/d3d9_state.h"

namespace dxvk 
{

namespace {
  bool exactMatch(const DrawCallState& drawCall, BlasEntry& blas) {
    auto isSky = [](CameraType::Enum t) {
      return t == CameraType::Sky;
    };

    if (isSky(drawCall.cameraType) != isSky(blas.input.cameraType)) {
      return false;
    }

    return drawCall.getMaterialData().getHash() == blas.input.getMaterialData().getHash()
        && drawCall.getGeometryData().getHashForRule<rules::FullGeometryHash>() == blas.input.getGeometryData().getHashForRule<rules::FullGeometryHash>()
        && drawCall.getSkinningState().boneHash == blas.input.getSkinningState().boneHash;
  }
}

DrawCallCache::DrawCallCache(DxvkDevice* device) : CommonDeviceObject(device) {
  m_entries.reserve(1024);
}
DrawCallCache::~DrawCallCache() {}

DrawCallCache::CacheState DrawCallCache::get(const DrawCallState& drawCall, BlasEntry** out) {
  // First, find the right bucket:
  const XXH64_hash_t hash = drawCall.getGeometryData().getHashForRule<rules::TopologicalHash>();
  auto range = m_entries.equal_range(hash);
  if (range.first == m_entries.end()) {
    // New bucket
    *out = allocateEntry(hash, drawCall);
    return CacheState::kNew;
  }
  // Handle buckets with 1 entry:
  auto iter = range.first;
  iter++;
  if (iter == range.second) {
    // Only 1 element
    BlasEntry& entry = range.first->second;

    const bool updatedThisFrame = entry.frameLastTouched == m_device->getCurrentFrameId();
    const bool vertexDataMatches = entry.input.getGeometryData().getHashForRule<rules::VertexDataHash>() == drawCall.getGeometryData().getHashForRule<rules::VertexDataHash>();
    const bool boneHashesMatch = entry.input.getSkinningState().boneHash == drawCall.getSkinningState().boneHash;
    const bool materialHashesMatch = entry.input.getMaterialData().getHash() == drawCall.getMaterialData().getHash();

    if (exactMatch(drawCall, entry) || !updatedThisFrame && (vertexDataMatches && boneHashesMatch || materialHashesMatch)) {
      // Exact vertex match that is reusable for the current draw call,
      // or something that hasn't been updated this frame and is similar enough.
      // Matching the logic in the multi-element loop below.
      *out = &entry;
      return CacheState::kExisted;
    } else {
      // First frame of having two mismatching instances, and the first instance has already 
      // been paired with the existing BlasEntry.
      *out = allocateEntry(hash, drawCall);
      return CacheState::kNew;
    }
  }

  // Bucket has multiple BlasEntries

  float bestScore = std::numeric_limits<float>::min();

  // Instance-pairing position. The lengthSqr distance term below decides which BlasEntry an incoming
  // draw maps to among same-TopologicalHash siblings (a swarm of same-type meshes). For world-space-
  // bone skinning (e.g. an indexed-blend path that bakes world placement into the bones and leaves
  // objectToWorld identity) every instance of a mesh shares an identical bind-pose bbox AND an
  // identity transform, so getTransformedCentroid(objectToWorld) is the SAME point for every instance
  // -> the tiebreaker collapses, instances get assigned to entries by draw order, and a distance-
  // sorted draw order shuffles as the camera moves -> each instance momentarily inherits a sibling's
  // (or a fresh, empty) motion history -> a distance-swept one-frame motion-vector smear. Transform
  // the bbox by a representative WORLD-SPACE bone instead: distinct per instance and smoothly moving,
  // so the nearest-position match is stably the same instance frame to frame (blas.input holds last
  // frame's bones, refreshed at SceneManager::onSceneObjectUpdated). Gated to
  // assumeWorldSpaceSkinnedBones; object-space-bone games keep the standard objectToWorld centroid.
  // Read the option once -- RtxOption::operator() locks a global mutex per read and the value is
  // loop-invariant across the candidate scan below.
  const bool worldSpaceBones = RtxOptions::assumeWorldSpaceSkinnedBones();
  auto pairingCentroid = [worldSpaceBones](const DrawCallState& dc) -> Vector3 {
    const SkinningData& sk = dc.getSkinningState();
    if (worldSpaceBones &&
        sk.numBones > sk.minBoneIndex && sk.minBoneIndex < sk.pBoneMatrices.size()) {
      return dc.getGeometryData().boundingBox.getTransformedCentroid(sk.pBoneMatrices[sk.minBoneIndex]);
    }
    return dc.getGeometryData().boundingBox.getTransformedCentroid(dc.getTransformData().objectToWorld);
  };
  const Vector3 newWorldPosition = pairingCentroid(drawCall);

  for (auto bucketIter = range.first; bucketIter != range.second; bucketIter++) {
    BlasEntry& blas  = bucketIter->second;
    if (exactMatch(drawCall, blas)) {
      *out = &blas;
      return CacheState::kExisted;
    }
    if (blas.frameLastTouched == m_device->getCurrentFrameId()) {
      continue;
    }
    // TODO these heuristics could use more refinement.
    float score = 0;
    if (blas.modifiedGeometryData.hashes[HashComponents::VertexPosition] == drawCall.getGeometryData().hashes[HashComponents::VertexPosition] &&
        blas.input.getSkinningState().boneHash == drawCall.getSkinningState().boneHash) {
      score += 1000.f;
    }
    if (blas.modifiedGeometryData.hashes[HashComponents::VertexTexcoord] == drawCall.getGeometryData().hashes[HashComponents::VertexTexcoord]) {
      score += 1000.f;
    }
    if (blas.input.getMaterialData().getHash() == drawCall.getMaterialData().getHash()) {
      score += 1000.f;
    }
    // Doesn't include the portal logic from InstanceManager. blas.input is refreshed each frame
    // (SceneManager::onSceneObjectUpdated), so pairingCentroid reads this candidate's last-frame
    // position -> one-frame distance for the same instance, large distance for a different one.
    const Vector3 worldPosition = pairingCentroid(blas.input);
    score -= lengthSqr(newWorldPosition - worldPosition);
    if (score > bestScore) {
      bestScore = score;
      *out = &blas;
    }
  }
  if (*out == nullptr) {
    // Failed to find similar blas, so allocate a new one
    *out = allocateEntry(hash, drawCall);
    return CacheState::kNew;
  }
  return CacheState::kExisted;

}

BlasEntry* DrawCallCache::allocateEntry(XXH64_hash_t hash, const DrawCallState& drawCall) {
  auto iter = m_entries.emplace(hash, drawCall);
  BlasEntry* result = &iter->second;
  result->frameCreated = m_device->getCurrentFrameId();
  if (RtxOptions::logGeometryLifecycle()) {
    Logger::info(str::format("[GeomLife] ", result->frameCreated,
      " BLASENTRY-NEW hash=0x", std::hex, hash,
      " assetHash=0x", drawCall.getHash(RtxOptions::geometryAssetHashRule()), std::dec,
      " tris=", drawCall.getGeometryData().calculatePrimitiveCount()));
  }
  return result;
}

}  // namespace nvvk
