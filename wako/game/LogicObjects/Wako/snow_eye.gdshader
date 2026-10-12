shader_type spatial;
// Keep depth testing against the original opaque skin. No surface offset,
// depth rewrite or cutout: the material next pass uses its exact skin/weights.
// Zero RGB additive blending preserves its colour and writes reactive alpha.
render_mode unshaded, blend_add, depth_draw_never, fog_disabled;

#define EYE_TEMPORAL_PASS
#include "res://LogicObjects/Wako/snow_skin_surface.gdshaderinc"
