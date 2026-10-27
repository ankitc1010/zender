// Zender's C interface to Manifold: one boolean of two closed meshes.
// Manifold's own C bindings need its CrossSection support, which Zender
// does not build.
#ifndef ZENDER_MANIFOLD_SHIM_H
#define ZENDER_MANIFOLD_SHIM_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// A triangle mesh: xyz per vertex, three vertex indices per triangle, and
// an id per triangle that the result reports back for every triangle it
// keeps or cuts from it.
typedef struct {
  const double* pos;
  uint32_t n_verts;
  const uint32_t* tris;
  uint32_t n_tris;
  const uint32_t* tri_id;
} zm_mesh;

typedef struct zm_result zm_result;

// Status: 0 success; Manifold::Error values are offset by where they arose.
enum {
  ZM_OK = 0,
  ZM_OUT_OF_MEMORY = 1,
  ZM_FAILED = 2,
  ZM_INPUT_A = 100,
  ZM_INPUT_B = 200,
  ZM_RESULT = 300,
};

// op: 0 union, 1 difference (a - b), 2 intersection.
int zm_boolean(const zm_mesh* a, const zm_mesh* b, int op, zm_result** out);
uint32_t zm_result_verts(const zm_result* r, const double** pos);
uint32_t zm_result_tris(const zm_result* r, const uint32_t** tris, const uint32_t** tri_id);
void zm_result_free(zm_result* r);

#ifdef __cplusplus
}
#endif

#endif
