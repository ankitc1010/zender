// See shim.h. Inputs that are not manifold as given (vertices duplicated
// along open edges, as in many STL files) are welded with MeshGL::Merge
// and tried once more, as the boolean design decision (Q3) says.

#include "shim.h"

#include <manifold/manifold.h>

#include <new>
#include <vector>

using manifold::Manifold;
using manifold::MeshGL64;
using manifold::OpType;

struct zm_result {
  std::vector<double> pos;
  std::vector<uint32_t> tris;
  std::vector<uint32_t> ids;
};

static int build(const zm_mesh* in, Manifold* out) {
  MeshGL64 m;
  m.numProp = 3;
  m.vertProperties.assign(in->pos, in->pos + 3 * size_t(in->n_verts));
  m.triVerts.assign(in->tris, in->tris + 3 * size_t(in->n_tris));
  m.faceID.assign(in->tri_id, in->tri_id + in->n_tris);
  *out = Manifold(m);
  if (out->Status() == Manifold::Error::NotManifold && m.Merge()) *out = Manifold(m);
  return static_cast<int>(out->Status());
}

extern "C" int zm_boolean(const zm_mesh* a, const zm_mesh* b, int op, zm_result** out) {
  *out = nullptr;
  try {
    Manifold ma, mb;
    int s = build(a, &ma);
    if (s != 0) return ZM_INPUT_A + s;
    s = build(b, &mb);
    if (s != 0) return ZM_INPUT_B + s;
    const OpType t = op == 0 ? OpType::Add : op == 1 ? OpType::Subtract : OpType::Intersect;
    const Manifold r = ma.Boolean(mb, t);
    s = static_cast<int>(r.Status());
    if (s != 0) return ZM_RESULT + s;
    const MeshGL64 m = r.GetMeshGL64();
    auto* res = new zm_result;
    const size_t n = m.NumVert();
    res->pos.resize(3 * n);
    for (size_t i = 0; i < n; i++)
      for (size_t k = 0; k < 3; k++) res->pos[3 * i + k] = m.vertProperties[i * m.numProp + k];
    res->tris.assign(m.triVerts.begin(), m.triVerts.end());
    res->ids.assign(m.faceID.begin(), m.faceID.end());
    *out = res;
    return ZM_OK;
  } catch (const std::bad_alloc&) {
    return ZM_OUT_OF_MEMORY;
  } catch (...) {
    return ZM_FAILED;
  }
}

extern "C" uint32_t zm_result_verts(const zm_result* r, const double** pos) {
  *pos = r->pos.data();
  return static_cast<uint32_t>(r->pos.size() / 3);
}

extern "C" uint32_t zm_result_tris(const zm_result* r, const uint32_t** tris, const uint32_t** tri_id) {
  *tris = r->tris.data();
  *tri_id = r->ids.data();
  return static_cast<uint32_t>(r->tris.size() / 3);
}

extern "C" void zm_result_free(zm_result* r) { delete r; }
