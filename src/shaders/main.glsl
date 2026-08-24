// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

// Raw strings have a limit of 64k, but MSVC has a limit of 2k in a string literal. This file is split into
// multiple raw strings that are concatenated by the compiler.

R"(shader_type spatial;
render_mode blend_mix,depth_draw_opaque,cull_back,diffuse_burley,specular_schlick_ggx,skip_vertex_transform;

/* The terrain depends on this shader to function. Don't change most things in vertex() or 
 * terrain normal calculations in fragment(). You probably only want to customize the 
 * material calculation and PBR application in fragment().
 *
 * Uniforms that begin with _ are private and will not display in the inspector. However, 
 * you can set them via code. You are welcome to create more of your own hidden uniforms.
 *
 * This system only supports albedo, height, normal, roughness. Most textures don't need the other
 * PBR channels. Height can be used as an approximation for AO. For the rare textures do need
 * additional channels, you can add maps for that one texture. e.g. an emissive map for lava.
 *
 */

// Defined Constants
#define SKIP_PASS 0
#define VERTEX_PASS 1
#define FRAGMENT_PASS 2
#define COLOR_MAP_DEF vec4(1.0, 1.0, 1.0, 0.5)
#define DIV_255 0.003921568627450 // 1. / 255.
#define DIV_1024 0.0009765625 // 1. / 1024.
#define TAU_16TH -0.392699081698724 // -TAU / 16.

// Inline Functions
// phases/2/13-terrain3d-integration.md: control-map bit layout widened twice
// (base/overlay 5->6->7 bits, 32->64->128 slots) -- see terrain_3d_util.h's
// own comment for the full old->new bit-offset table. Must stay in exact
// lockstep with that file and every other shader here that decodes/encodes
// this same format.
#define DECODE_BLEND(control) float(control >> 10u & 0xFFu) * DIV_255
#define DECODE_AUTO(control) bool(control & 0x1u)
#define DECODE_BASE(control) int(control >> 25u & 0x7Fu)
#define DECODE_OVER(control) int(control >> 18u & 0x7Fu)
#define DECODE_ANGLE(control) float(control >>6u & 0xFu) * TAU_16TH
// This math recreates the scale value directly rather than using an 8 float const array.
#define DECODE_SCALE(control) (0.9 - float(((control >>3u & 0x7u) + 3u) % 8u + 1u) * 0.1)
#define DECODE_HOLE(control) bool(control >>2u & 0x1u)

#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
    #define fma(a, b, c) ((a) * (b) + (c))
    #define dFdxCoarse(a) dFdx(a)
    #define dFdyCoarse(a) dFdy(a)
#endif

// Private uniforms
uniform vec3 _camera_pos = vec3(0.f);
uniform float _mesh_size = 48.f;
uniform uint _background_mode = 1u; // NONE = 0, FLAT = 1, NOISE = 2
uniform uint _mouse_layer = 0x80000000u; // Layer 32
uniform float _vertex_spacing = 1.0;
uniform float _vertex_density = 1.0; // = 1./_vertex_spacing
uniform float _region_size = 1024.0;
uniform float _region_texel_size = 0.0009765625; // = 1./region_size
uniform int _region_map_size = 32;
uniform int _region_map[1024];
uniform vec2 _region_locations[1024];
// phases/2/14-native-terrain-texture-blend.md: real bug found via a live-play
// report of consistent (deterministic, not random) solid-white terrain
// patches -- these were fixed-size [32], a latent pre-existing limit dating
// to Terrain3D's old 5-bit/32-slot control-map era, never widened when this
// project's own control-map bit-width widenings (5->6->7 bits, 32->64->128
// slots, phases/2/13) or this doc's real N=7 per-vertex system raised the
// real usable texture-pool budget. Terrain3DAssets::MAX_TEXTURES is 128 and
// the C++ side (get_texture_colors() etc., terrain_3d_material.cpp) already
// sends a correctly-sized array up to that -- only this shader-side
// declaration was stuck at 32. Any real texture ID >=32 (confirmed directly:
// a real live cell's own resolved pool slots included 32 and 39) read past
// this array's declared bounds, genuinely undefined GLSL behavior -- the
// real, deterministic (once texture-pool resolution order became
// deterministic via prewarm_textures()) cause of the corruption. Widened to
// 128 to match MAX_TEXTURES exactly, not just "big enough for now."
uniform float _texture_normal_depth_array[128];
uniform float _texture_ao_strength_array[128];
uniform float _texture_roughness_mod_array[128];
uniform float _texture_uv_scale_array[128];
uniform vec2 _texture_detile_array[128];
uniform vec4 _texture_color_array[128];
// The real ESM LTEX slot carried by the N=7 per-vertex maps is deliberately
// distinct from the deduplicated Terrain3D render-texture slot: LTEX.GNAM
// grass ownership must survive even when two LTEX records share one DDS.
// terrain3d_bridge.gd prewarms this fixed lookup deterministically.
uniform int _ltex_to_render_slot[128];
uniform highp sampler2DArray _height_maps : repeat_disable;
uniform highp sampler2DArray _control_maps : repeat_disable;
// phases/2/14-native-terrain-texture-blend.md: real per-vertex N=7 layer data,
// always texelFetch'd at exact vertex indices (never texture()/textureLod()),
// so filtering mode is irrelevant here -- same reasoning as _control_maps above.
uniform highp sampler2DArray _tex_id_a_maps : repeat_disable;
uniform highp sampler2DArray _tex_id_b_maps : repeat_disable;
uniform highp sampler2DArray _weight_a_maps : repeat_disable;
uniform highp sampler2DArray _weight_b_maps : repeat_disable;
uniform highp sampler2DArray _normal_maps : repeat_disable;
//INSERT: TEXTURE_SAMPLERS_NEAREST
//INSERT: TEXTURE_SAMPLERS_LINEAR

// Public uniforms
//INSERT: AUTO_SHADER_UNIFORMS
//INSERT: DUAL_SCALING_UNIFORMS
uniform float blend_sharpness : hint_range(0, 1) = 0.5;
uniform bool flat_terrain_normals = false;
uniform bool enable_projection = true;
uniform float projection_threshold : hint_range(0.0, 0.99, 0.01) = 0.8;

uniform float mipmap_bias : hint_range(0.5, 1.5, 0.01) = 1.0;
uniform float depth_blur : hint_range(0.0, 35.0, 0.1) = 0.0;
uniform float bias_distance : hint_range(0.0, 16384.0, 0.1) = 512.0;

uniform bool enable_macro_variation = true;
uniform vec3 macro_variation1 : source_color = vec3(1.);
uniform vec3 macro_variation2 : source_color = vec3(1.);
uniform float macro_variation_slope : hint_range(0., 1.)  = 0.333;

// Generic noise at 2 scales, which can be used for anything 
//INSERT: NOISE_SAMPLER_NEAREST
//INSERT: NOISE_SAMPLER_LINEAR
uniform float noise1_scale : hint_range(0.001, 1.) = 0.04; // Used for macro variation 1. Scaled up 10x
uniform float noise1_angle : hint_range(0, 6.283) = 0.;
uniform vec2 noise1_offset = vec2(0.5);
uniform float noise2_scale : hint_range(0.001, 1.) = 0.076;	// Used for macro variation 2. Scaled up 10x

// Varyings & Types

struct material {
	vec4 albedo_height;
	vec4 normal_rough;
	float normal_map_depth;
	float ao_strength;
	float total_weight;
};

// phases/2/14-native-terrain-texture-blend.md: one real texture-array sample
// (albedo+height, normal+rough, normal depth, ao strength) for a single real
// layer at a single corner. Composited by accumulate_material() below via
// real sequential alpha-over, not Terrain3D's own competitive height-blend.
struct layer_sample {
	vec4 albedo;
	vec4 normal_rough;
	float normal_map_depth;
	float ao_strength;
};

varying float v_vertex_xz_dist;
varying vec3 v_vertex;
)"

		R"(
////////////////////////
// Vertex
////////////////////////

// Takes in world space XZ (UV) coordinates & search depth (only applicable for background mode none)
// Returns ivec3 with:
// XY: (0 to _region_size - 1) coordinates within a region
// Z: layer index used for texturearrays, -1 if not in a region
ivec3 get_index_coord(const vec2 uv, const int search) {
	vec2 r_uv = round(uv);
	vec2 o_uv = mod(r_uv,_region_size);
	ivec2 pos;
	int bounds, layer_index = -1;
	for (int i = -1; i < clamp(search, SKIP_PASS, FRAGMENT_PASS); i++) {
		if ((layer_index == -1 && _background_mode == 0u ) || i < 0) {
			r_uv -= i == -1 ? vec2(0.0) : vec2(float(o_uv.x <= o_uv.y), float(o_uv.y <= o_uv.x));
			pos = ivec2(floor((r_uv) * _region_texel_size)) + (_region_map_size / 2);
			bounds = int(uint(pos.x | pos.y) < uint(_region_map_size));
			layer_index = (_region_map[ pos.y * _region_map_size + pos.x ] * bounds - 1);
		}
	}
	return ivec3(ivec2(mod(r_uv,_region_size)), layer_index);
}

// Takes in descaled (world_space / region_size) world to region space XZ (UV2) coordinates, returns vec3 with:
// XY: (0. to 1.) coordinates within a region
// Z: layer index used for texturearrays, -1 if not in a region
vec3 get_index_uv(const vec2 uv2) {
	ivec2 pos = ivec2(floor(uv2)) + (_region_map_size / 2);
	int bounds = int(uint(pos.x | pos.y) < uint(_region_map_size));
	int layer_index = _region_map[ pos.y * _region_map_size + pos.x ] * bounds - 1;
	return vec3(uv2 - _region_locations[layer_index], float(layer_index));
}

//INSERT: WORLD_NOISE1
void vertex() {
	// Get vertex of flat plane in world coordinates and set world UV
	v_vertex = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;

	// Camera distance to vertex on flat plane
	v_vertex_xz_dist = length(v_vertex.xz - _camera_pos.xz);

	// Geomorph vertex, set end and start for linear height interpolate
	float scale = MODEL_MATRIX[0][0];
	float vertex_lerp = smoothstep(0.55, 0.95, (v_vertex_xz_dist / scale - _mesh_size - 4.0) / (_mesh_size - 2.0));
	vec2 v_fract = fract(VERTEX.xz * 0.5) * 2.0;
	// For LOD0 morph from a regular grid to an alternating grid to align with LOD1+
	vec2 shift = (scale < _vertex_spacing + 1e-6) ? // LOD0 or not
		// Shift from regular to symetric
		mix(v_fract, vec2(v_fract.x, -v_fract.y),
			round(fract(round(mod(v_vertex.z * _vertex_density, 4.0)) *
			round(mod(v_vertex.x * _vertex_density, 4.0)) * 0.25))
			) :
		// Symetric shift
		v_fract * round((fract(v_vertex.xz * 0.25 / scale) - 0.5) * 4.0);
	vec2 start_pos = v_vertex.xz * _vertex_density;
	vec2 end_pos = (v_vertex.xz - shift * scale) * _vertex_density;
	v_vertex.xz -= shift * scale * vertex_lerp;

	// UV coordinates in world space. Values are 0 to _region_size within regions
	UV = v_vertex.xz * _vertex_density;

	// UV coordinates in region space + texel offset. Values are 0 to 1 within regions
	UV2 = fma(UV, vec2(_region_texel_size), vec2(0.5 * _region_texel_size));

	// Discard vertices for Holes. 1 lookup
	ivec3 v_region = get_index_coord(start_pos, VERTEX_PASS);
	uint control = floatBitsToUint(texelFetch(_control_maps, v_region, 0)).r;
	bool hole = DECODE_HOLE(control);

	// Show holes to all cameras except mouse camera (on exactly 1 layer)
	if ( !(CAMERA_VISIBLE_LAYERS == _mouse_layer) && 
			(hole || (_background_mode == 0u && v_region.z == -1))) {
		v_vertex.x = 0. / 0.;
	} else {		
		// Set final vertex height & calculate vertex normals. 3 lookups
		ivec3 coord_a = get_index_coord(start_pos, VERTEX_PASS);
		ivec3 coord_b = get_index_coord(end_pos, VERTEX_PASS);
		float h = mix(texelFetch(_height_maps, coord_a, 0).r,texelFetch(_height_maps, coord_b, 0).r,vertex_lerp);
//INSERT: WORLD_NOISE2
		v_vertex.y = h;
	}

	// Convert model space to view space w/ skip_vertex_transform render mode
	VERTEX = (VIEW_MATRIX * vec4(v_vertex, 1.0)).xyz;
	NORMAL = normalize((MODELVIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	BINORMAL = normalize((MODELVIEW_MATRIX * vec4(BINORMAL, 0.0)).xyz);
	TANGENT = normalize((MODELVIEW_MATRIX * vec4(TANGENT, 0.0)).xyz);
}
)"

		R"(
////////////////////////
// Fragment
////////////////////////

float random(in vec2 xy) {
	return fract(sin(dot(xy, vec2(12.9898, 78.233))) * 43758.5453);
}

vec2 rotate_vec2(const vec2 v, const vec2 cs) {
	return vec2(fma(cs.x, v.x,  cs.y * v.y), fma(cs.x, v.y, -cs.y * v.x));
}

// Samples one real texture layer with Terrain3D's existing detiling/rotation/
// projection-aligned anisotropic filtering, shared by every one of the up to
// 7 real layers accumulate_material() below composites. Factored out of what
// used to be two near-identical inline blocks (one per control-map texture
// ID) so real N=7 compositing doesn't require 7x copy-pasted blocks.
layer_sample sample_terrain_layer(const int id, const vec2 i_uv, const vec4 i_dd, const vec2 i_pos,
			const vec2 c_cs_angle, const mat2 p_align) {
	int render_id = _ltex_to_render_slot[id];
	float id_scale = _texture_uv_scale_array[render_id];
	vec4 id_dd = i_dd * id_scale;

	// Detiling and Control map rotation
	vec2 uv_center = floor(fma(i_pos, vec2(id_scale), vec2(0.5)));
	vec2 id_detile = fma(random(uv_center), 2.0, -1.0) * _texture_detile_array[render_id] * TAU;
	vec2 id_cs_angle = vec2(cos(id_detile.x), sin(id_detile.x));
	// Apply UV rotation and shift around pivot.
	vec2 id_uv = rotate_vec2(fma(i_uv, vec2(id_scale), -uv_center), id_cs_angle) + uv_center + id_detile.y - 0.5;
	// Manual transpose to rotate derivatives and normals counter to uv rotation whilst also
	// including control map rotation. avoids extra matrix op, and sin/cos calls.
	id_cs_angle = vec2(
		fma(id_cs_angle.x, c_cs_angle.x, -id_cs_angle.y * c_cs_angle.y),
		fma(id_cs_angle.y, c_cs_angle.x, id_cs_angle.x * c_cs_angle.y));
	// Align derivatives for correct anisotropic filtering
	id_dd.xy = rotate_vec2(id_dd.xy, id_cs_angle);
	id_dd.zw = rotate_vec2(id_dd.zw, id_cs_angle);

	vec4 alb = textureGrad(_texture_array_albedo, vec3(id_uv, float(render_id)), id_dd.xy, id_dd.zw);
	vec4 nrm = textureGrad(_texture_array_normal, vec3(id_uv, float(render_id)), id_dd.xy, id_dd.zw);

	alb.rgb *= _texture_color_array[render_id].rgb;
	nrm.a = clamp(nrm.a + _texture_roughness_mod_array[render_id], 0., 1.);
	// Unpack and rotate normal map.
	nrm.xyz = fma(nrm.xzy, vec3(2.0), vec3(-1.0));
	nrm.xz = rotate_vec2(nrm.xz, id_cs_angle) * p_align;

	return layer_sample(alb, nrm, _texture_normal_depth_array[render_id], _texture_ao_strength_array[render_id]);
}

// phases/2/14-native-terrain-texture-blend.md: real sequential alpha-over
// compositing of up to 7 real layers at one corner -- ids_a/ids_b are the
// real BTXT+ATXT texture IDs (ids_a.x is always the real BTXT base, implicit
// weight 1.0), weights_a/weights_b are the real per-vertex VTXT opacities for
// the 6 possible ATXT overlays, already sorted by real layer_index at import
// time. Replaces Terrain3D's own competitive 2-texture height-blend model
// entirely -- there is no "which id wins" logic here, just the literal
// engine algorithm: base, then each real overlay painted over it in order.
void accumulate_material(const vec3 base_ddx, const vec3 base_ddy, const float weight, const ivec3 index,
			const ivec4 ids_a, const ivec3 ids_b, const vec4 weights_a, const vec2 weights_b,
			const vec3 i_normal, const float h, inout material mat) {

	// Index position for detiling.
	vec2 i_pos = fma(_region_locations[index.z], vec2(_region_size), vec2(index.xy)) * _vertex_spacing;

	// Projection
	vec2 i_uv = v_vertex.xz;
	vec4 i_dd = vec4(base_ddx.xz, base_ddy.xz);
	mat2 p_align = mat2(1.);
	if (i_normal.y <= projection_threshold && enable_projection) {
		// Projected normal map alignment matrix
		p_align = mat2(vec2(i_normal.z, -i_normal.x), vec2(i_normal.x, i_normal.z));
		// Fast 45 degree snapping https://iquilezles.org/articles/noatan/
		vec2 xz = round(normalize(-i_normal.xz) * 1.3065629648763765); // sqrt(1.0 + sqrt(0.5))
		xz *= abs(xz.x) + abs(xz.y) > 1.5 ? 0.7071067811865475 : 1.0; // sqrt(0.5)
		xz = vec2(-xz.y, xz.x);
		i_pos = floor(vec2(dot(i_pos, xz), -h));
		i_uv = vec2(dot(v_vertex.xz, xz), -v_vertex.y);
		i_dd.xy = vec2(dot(base_ddx.xz, xz), -base_ddx.y);
		i_dd.zw = vec2(dot(base_ddy.xz, xz), -base_ddy.y);
	}
	// No control-map scale/rotation here -- those were properties of
	// Terrain3D's own control-map format, not real ESM data. Real per-texture
	// UV scale/detiling still comes from _texture_uv_scale_array/_texture_detile_array,
	// same as before, just with no additional per-vertex rotation on top.
	const vec2 c_cs_angle = vec2(1.0, 0.0);

	int ids[7] = int[7](ids_a.x, ids_a.y, ids_a.z, ids_a.w, ids_b.x, ids_b.y, ids_b.z);
	float layer_w[7] = float[7](1.0, weights_a.x, weights_a.y, weights_a.z, weights_a.w, weights_b.x, weights_b.y);

	vec4 accum_albedo = vec4(0.0);
	vec4 accum_normal = vec4(0.0);
	float accum_normal_depth = 0.0;
	float accum_ao = 0.0;

	// Layer 0 (real BTXT base) is always opaque and always present.
	layer_sample base = sample_terrain_layer(ids[0], i_uv, i_dd, i_pos, c_cs_angle, p_align);
	accum_albedo = base.albedo;
	accum_normal = base.normal_rough;
	accum_normal_depth = base.normal_map_depth;
	accum_ao = base.ao_strength;

	// Real ATXT overlays 1-6, each alpha-over by its own real VTXT weight, in
	// real authored layer_index order (already sorted at import time).
	for (int layer = 1; layer < 7; layer++) {
		float a = layer_w[layer];
		if (a <= 0.0) {
			continue;
		}
		layer_sample s = sample_terrain_layer(ids[layer], i_uv, i_dd, i_pos, c_cs_angle, p_align);
		a = clamp(a, 0.0, 1.0);
		accum_albedo = mix(accum_albedo, s.albedo, a);
		accum_normal = mix(accum_normal, s.normal_rough, a);
		accum_normal_depth = mix(accum_normal_depth, s.normal_map_depth, a);
		accum_ao = mix(accum_ao, s.ao_strength, a);
	}

	mat.albedo_height = fma(accum_albedo, vec4(weight), mat.albedo_height);
	mat.normal_rough = fma(accum_normal, vec4(weight), mat.normal_rough);
	mat.normal_map_depth = fma(accum_normal_depth, weight, mat.normal_map_depth);
	mat.ao_strength = fma(accum_ao, weight, mat.ao_strength);
	mat.total_weight += weight;
}

void fragment() {
	// Recover UVs
	vec2 uv = UV;
	vec2 uv2 = UV2;
	
	// Lookup offsets, ID and blend weight
	vec3 region_uv = get_index_uv(uv2);
	const vec3 offsets = vec3(0, 1, 2);
	vec2 index_id = floor(uv);
	vec2 weight = fract(uv);
	vec2 invert = 1.0 - weight;
	vec4 weights = vec4(
		invert.x * weight.y, // 0
		weight.x * weight.y, // 1
		weight.x * invert.y, // 2
		invert.x * invert.y  // 3
	);

	ivec3 index[4];
	// control map lookups, used for some normal lookups as well
	index[0] = get_index_coord(index_id + offsets.xy, FRAGMENT_PASS);
	index[1] = get_index_coord(index_id + offsets.yy, FRAGMENT_PASS);
	index[2] = get_index_coord(index_id + offsets.yx, FRAGMENT_PASS);
	index[3] = get_index_coord(index_id + offsets.xx, FRAGMENT_PASS);
	
	vec3 base_ddx = dFdxCoarse(v_vertex);
	vec3 base_ddy = dFdyCoarse(v_vertex);
	// Calculate the effective mipmap for regionspace, and when less than 0,
	// skip all extra lookups required for bilinear blend.
	float region_mip = log2(max(length(base_ddx.xz), length(base_ddy.xz)) * _vertex_density);
	bool bilerp = region_mip < 0.0 && region_uv.z > -1.;

	// Terrain normals
	// phases/2/14-native-terrain-texture-blend.md: real per-vertex normals,
	// read directly from _normal_maps instead of recomputed from height
	// differences. terrain3d_bridge.gd always populates this map at import
	// time -- either the real authored VNML normal, or (when
	// import_authored_normals is off, or a cell has no real VNML) the same
	// central-difference-from-heights formula this block used to compute
	// live, baked in once at import instead of every fragment. Encoded as
	// (world_normal+1)/2 (Terrain3DRegion::COLOR_NORMAL_UP's own convention),
	// decoded back here via *2-1. This also drops WORLD_NOISE3's live
	// height-diff perturbation (an editor-only brush-preview convenience,
	// never enabled in this project -- same real, deliberate scope cut as
	// auto_shader/dual_scaling above).
	vec3 index_normal[4];
	float h[4];

	// Re-use index[] for the first lookups, skipping some math. 3 lookups
	h[3] = texelFetch(_height_maps, index[3], 0).r; // 0 (0,0)
	h[2] = texelFetch(_height_maps, index[2], 0).r; // 1 (1,0)
	h[0] = texelFetch(_height_maps, index[0], 0).r; // 2 (0,1)
	index_normal[3] = normalize(texelFetch(_normal_maps, index[3], 0).xyz * 2.0 - 1.0);

	// Set flat world normal - overwritten if bilerp is true
	vec3 w_normal = index_normal[3];

	// Adjust derivatives for mipmap bias and depth blur effect
	float bias = mix(mipmap_bias,
		depth_blur + 1.,
		smoothstep(0.0, 1.0, (v_vertex_xz_dist - bias_distance) * DIV_1024));
	base_ddx *= bias;
	base_ddy *= bias;

	// Color map
	vec4 color_map = region_uv.z > -1.0 ? textureLod(_color_maps, region_uv, region_mip) : COLOR_MAP_DEF;

	// Branching smooth normals and manually interpolated color map - fixes cross region artifacts
	if (bilerp) {
		// 4 lookups if linear filtering, else 1 lookup.
		vec4 col_map[4];
		col_map[3] = index[3].z > -1 ? texelFetch(_color_maps, index[3], 0) : COLOR_MAP_DEF;
		#ifdef FILTER_LINEAR
		col_map[0] = index[0].z > -1 ? texelFetch(_color_maps, index[0], 0) : COLOR_MAP_DEF;
		col_map[1] = index[1].z > -1 ? texelFetch(_color_maps, index[1], 0) : COLOR_MAP_DEF;
		col_map[2] = index[2].z > -1 ? texelFetch(_color_maps, index[2], 0) : COLOR_MAP_DEF;

		color_map =
			col_map[0] * weights[0] +
			col_map[1] * weights[1] +
			col_map[2] * weights[2] +
			col_map[3] * weights[3] ;
		#else
		color_map = col_map[3];
		#endif

		h[1] = texelFetch(_height_maps, index[1], 0).r; // needed by accumulate_material's h param below

		// Real per-vertex normals for the remaining corners -- same
		// texelFetch-from-_normal_maps decode as corner 3 above.
		index_normal[0] = normalize(texelFetch(_normal_maps, index[0], 0).xyz * 2.0 - 1.0);
		index_normal[1] = normalize(texelFetch(_normal_maps, index[1], 0).xyz * 2.0 - 1.0);
		index_normal[2] = normalize(texelFetch(_normal_maps, index[2], 0).xyz * 2.0 - 1.0);

		// Set interpolated world normal
		w_normal =
			index_normal[0] * weights[0] +
			index_normal[1] * weights[1] +
			index_normal[2] * weights[2] +
			index_normal[3] * weights[3] ;
	}

	// Apply terrain normals
	if (flat_terrain_normals) {
		NORMAL = normalize(cross(dFdyCoarse(VERTEX),dFdxCoarse(VERTEX)));
		TANGENT = normalize(cross(NORMAL, VIEW_MATRIX[2].xyz));
		BINORMAL = normalize(cross(NORMAL, TANGENT));
	} else {
		vec3 w_tangent = normalize(cross(w_normal, vec3(0.0, 0.0, 1.0)));
		vec3 w_binormal = normalize(cross(w_normal, w_tangent));
		NORMAL = mat3(VIEW_MATRIX) * w_normal;
		TANGENT = mat3(VIEW_MATRIX) * w_tangent;
		BINORMAL = mat3(VIEW_MATRIX) * w_binormal;
	}

	// Real per-vertex N=7 layer data -- texture IDs + blend weights, read
	// directly from the real ESM-driven per-vertex maps (see
	// phases/2/14-native-terrain-texture-blend.md). No bit-packing, no
	// control-map decode: this replaces the old 2-texture competitive-blend
	// control-map section entirely. IDs are stored normalized 0-1 (real
	// Godot Image has no 8-bit integer format) and decoded via round(*255).
	// 1 - 4 lookups per array, same bilerp-gated pattern as height/color above.
	ivec4 ids_a[4];
	ivec3 ids_b[4];
	vec4 w_a[4];
	vec2 w_b[4];

	ids_a[3] = ivec4(round(texelFetch(_tex_id_a_maps, index[3], 0) * 255.0));
	ids_b[3] = ivec3(round(texelFetch(_tex_id_b_maps, index[3], 0).rgb * 255.0));
	w_a[3] = texelFetch(_weight_a_maps, index[3], 0);
	w_b[3] = texelFetch(_weight_b_maps, index[3], 0).rg;

	if (bilerp) {
		ids_a[0] = ivec4(round(texelFetch(_tex_id_a_maps, index[0], 0) * 255.0));
		ids_b[0] = ivec3(round(texelFetch(_tex_id_b_maps, index[0], 0).rgb * 255.0));
		w_a[0] = texelFetch(_weight_a_maps, index[0], 0);
		w_b[0] = texelFetch(_weight_b_maps, index[0], 0).rg;

		ids_a[1] = ivec4(round(texelFetch(_tex_id_a_maps, index[1], 0) * 255.0));
		ids_b[1] = ivec3(round(texelFetch(_tex_id_b_maps, index[1], 0).rgb * 255.0));
		w_a[1] = texelFetch(_weight_a_maps, index[1], 0);
		w_b[1] = texelFetch(_weight_b_maps, index[1], 0).rg;

		ids_a[2] = ivec4(round(texelFetch(_tex_id_a_maps, index[2], 0) * 255.0));
		ids_b[2] = ivec3(round(texelFetch(_tex_id_b_maps, index[2], 0).rgb * 255.0));
		w_a[2] = texelFetch(_weight_a_maps, index[2], 0);
		w_b[2] = texelFetch(_weight_b_maps, index[2], 0).rg;
	}

	// Struct to accumulate all texture data.
	material mat = material(vec4(0.0), vec4(0.0), 0., 0., 0.);

	// Each corner independently composites its own real up-to-7-layer stack
	// via accumulate_material()'s sequential alpha-over, then that corner's
	// single shaded result is blended into `mat` by the corner's own mesh
	// interpolation weight -- same fma-accumulate pattern as before, just
	// once per corner instead of once per corner per competitive texture ID.
	accumulate_material(base_ddx, base_ddy, weights[3], index[3], ids_a[3], ids_b[3], w_a[3], w_b[3],
		index_normal[3], h[3], mat);

	if (bilerp) {
		accumulate_material(base_ddx, base_ddy, weights[2], index[2], ids_a[2], ids_b[2], w_a[2], w_b[2],
			index_normal[2], h[2], mat);
		accumulate_material(base_ddx, base_ddy, weights[1], index[1], ids_a[1], ids_b[1], w_a[1], w_b[1],
			index_normal[1], h[1], mat);
		accumulate_material(base_ddx, base_ddy, weights[0], index[0], ids_a[0], ids_b[0], w_a[0], w_b[0],
			index_normal[0], h[0], mat);
	}

	// normalize accumulated values back to 0.0 - 1.0 range.
	float weight_inv = 1.0 / mat.total_weight;
	mat.albedo_height *= weight_inv;
	mat.normal_rough *= weight_inv;
	mat.normal_map_depth *= weight_inv;
	mat.ao_strength *= weight_inv;

	// Macro variation. 2 lookups
	vec3 macrov = vec3(1.);
	if (enable_macro_variation) {
		float noise1 = texture(noise_texture, rotate_vec2(fma(uv, vec2(noise1_scale * .1), noise1_offset) , vec2(cos(noise1_angle), sin(noise1_angle)))).r;
		float noise2 = texture(noise_texture, uv * noise2_scale * .1).r;
		macrov = mix(macro_variation1, vec3(1.), noise1);
		macrov *= mix(macro_variation2, vec3(1.), noise2);
		macrov = mix(vec3(1.0), macrov, clamp(w_normal.y + macro_variation_slope, 0., 1.));
	}
	
	// Wetness/roughness modifier, converting 0 - 1 range to -1 to 1 range, clamped to Godot roughness values 
	float roughness = clamp(fma(color_map.a - 0.5, 2.0, mat.normal_rough.a), 0., 1.);
	
	// Apply PBR
	ALBEDO = mat.albedo_height.rgb * color_map.rgb * macrov;
	ROUGHNESS = roughness;
	SPECULAR = 1. - mat.normal_rough.a;
	// Repack final normal map value.
	NORMAL_MAP = fma(normalize(mat.normal_rough.xzy), vec3(0.5), vec3(0.5));
	NORMAL_MAP_DEPTH = mat.normal_map_depth;

	// Higher and/or facing up, less occluded.
	float ao = (1. - (mat.albedo_height.a * log(2.1 - mat.ao_strength))) * (1. - mat.normal_rough.y);
	AO = clamp(1. - ao * mat.ao_strength, mat.albedo_height.a, 1.0);
	AO_LIGHT_AFFECT = (1.0 - mat.albedo_height.a) * clamp(mat.normal_rough.y, 0., 1.);

}

)"
