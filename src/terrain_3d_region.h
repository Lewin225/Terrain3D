// Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.

#ifndef TERRAIN3D_REGION_CLASS_H
#define TERRAIN3D_REGION_CLASS_H

#include "constants.h"
#include "terrain_3d_util.h"

using namespace godot;

class Terrain3DRegion : public Resource {
	GDCLASS(Terrain3DRegion, Resource);
	CLASS_NAME();

public: // Constants
	enum MapType {
		TYPE_HEIGHT,
		TYPE_CONTROL,
		TYPE_COLOR,
		TYPE_TEX_ID_A, // Real per-vertex texture IDs, layers 0-3 (0=BTXT base, 1-3=ATXT by layer_index). See phases/2/14.
		TYPE_TEX_ID_B, // Real per-vertex texture IDs, layers 4-6 (ATXT), channel A spare
		TYPE_WEIGHT_A, // Real per-vertex ATXT/VTXT blend weights, overlay layers 1-4
		TYPE_WEIGHT_B, // Real per-vertex ATXT/VTXT blend weights, overlay layers 5-6, channels B/A spare
		TYPE_NORMAL, // Real per-vertex VNML authored normal, (n+1)/2 encoded, channel A spare
		TYPE_MAX,
	};

	static inline const Image::Format FORMAT[] = {
		Image::FORMAT_RF, // TYPE_HEIGHT
		Image::FORMAT_RF, // TYPE_CONTROL
		Image::FORMAT_RGBA8, // TYPE_COLOR
		Image::FORMAT_RGBA8, // TYPE_TEX_ID_A
		Image::FORMAT_RGBA8, // TYPE_TEX_ID_B
		Image::FORMAT_RGBA8, // TYPE_WEIGHT_A
		Image::FORMAT_RGBA8, // TYPE_WEIGHT_B
		Image::FORMAT_RGBA8, // TYPE_NORMAL
		Image::Format(TYPE_MAX), // Proper size of array instead of FORMAT_MAX
	};

	static inline const char *TYPESTR[] = {
		"TYPE_HEIGHT",
		"TYPE_CONTROL",
		"TYPE_COLOR",
		"TYPE_TEX_ID_A",
		"TYPE_TEX_ID_B",
		"TYPE_WEIGHT_A",
		"TYPE_WEIGHT_B",
		"TYPE_NORMAL",
		"TYPE_MAX",
	};

	static inline const Color COLOR[] = {
		COLOR_BLACK, // TYPE_HEIGHT
		COLOR_CONTROL, // TYPE_CONTROL
		COLOR_ROUGHNESS, // TYPE_COLOR
		COLOR_ZERO, // TYPE_TEX_ID_A -- id 0 is harmless default, overlay weight 0 means it never contributes
		COLOR_ZERO, // TYPE_TEX_ID_B
		COLOR_ZERO, // TYPE_WEIGHT_A -- all overlay weights 0 by default: only the implicit BTXT base shows
		COLOR_ZERO, // TYPE_WEIGHT_B
		COLOR_NORMAL_UP, // TYPE_NORMAL -- (0,1,0) encoded as (0.5, 1.0, 0.5), matches computed-normal fallback on flat ground
		COLOR_NAN, // TYPE_MAX, unused just in case someone indexes the array
	};

private:
	// Saved data
	real_t _version = 0.8f; // Set to first version to ensure we always upgrades this
	int _region_size = 0;
	Vector2 _height_range = V2_ZERO;
	// Maps
	Ref<Image> _height_map;
	Ref<Image> _control_map;
	Ref<Image> _color_map;
	Ref<Image> _tex_id_a_map;
	Ref<Image> _tex_id_b_map;
	Ref<Image> _weight_a_map;
	Ref<Image> _weight_b_map;
	Ref<Image> _normal_map;
	// Instancer
	Dictionary _instances; // Meshes{int} -> Cells{v2i} -> [ Transform3D, Color, Modified ]
	real_t _vertex_spacing = 1.f; // Vertex Spacing value that transforms are currently scaled.

	// Working data not saved to disk
	bool _deleted = false; // Marked for deletion on save
	bool _edited = false; // Marked for undo/redo storage
	bool _modified = false; // Marked for saving
	Vector2i _location = V2I_MAX;

public:
	Terrain3DRegion() {}
	~Terrain3DRegion() {}

	void set_version(const real_t p_version);
	real_t get_version() const { return _version; }
	void set_region_size(const int p_region_size) { _region_size = CLAMP(p_region_size, 64, 2048); }
	int get_region_size() const { return _region_size; }

	// Maps
	void set_map(const MapType p_map_type, const Ref<Image> &p_image);
	Ref<Image> get_map(const MapType p_map_type) const;
	Image *get_map_ptr(const MapType p_map_type) const;
	void set_maps(const TypedArray<Image> &p_maps);
	TypedArray<Image> get_maps() const;
	void set_height_map(const Ref<Image> &p_map);
	Ref<Image> get_height_map() const { return _height_map; }
	void set_control_map(const Ref<Image> &p_map);
	Ref<Image> get_control_map() const { return _control_map; }
	void set_color_map(const Ref<Image> &p_map);
	Ref<Image> get_color_map() const { return _color_map; }
	void set_tex_id_a_map(const Ref<Image> &p_map);
	Ref<Image> get_tex_id_a_map() const { return _tex_id_a_map; }
	void set_tex_id_b_map(const Ref<Image> &p_map);
	Ref<Image> get_tex_id_b_map() const { return _tex_id_b_map; }
	void set_weight_a_map(const Ref<Image> &p_map);
	Ref<Image> get_weight_a_map() const { return _weight_a_map; }
	void set_weight_b_map(const Ref<Image> &p_map);
	Ref<Image> get_weight_b_map() const { return _weight_b_map; }
	void set_normal_map(const Ref<Image> &p_map);
	Ref<Image> get_normal_map() const { return _normal_map; }
	void sanitize_maps();
	Ref<Image> sanitize_map(const MapType p_map_type, const Ref<Image> &p_map) const;
	bool validate_map_size(const Ref<Image> &p_map) const;

	void set_height_range(const Vector2 &p_range);
	Vector2 get_height_range() const { return _height_range; }
	void update_height(const real_t p_height);
	void update_heights(const Vector2 &p_low_high);
	void calc_height_range();

	// Instancer
	void set_instances(const Dictionary &p_instances) { _instances = p_instances; }
	Dictionary get_instances() const { return _instances; }
	void set_vertex_spacing(const real_t p_vertex_spacing) { _vertex_spacing = CLAMP(p_vertex_spacing, 0.25f, 100.f); }
	real_t get_vertex_spacing() const { return _vertex_spacing; }

	// File I/O
	Error save(const String &p_path = "", const bool p_16_bit = false);

	// Working Data
	void set_deleted(const bool p_deleted) { _deleted = p_deleted; }
	bool is_deleted() const { return _deleted; }
	void set_edited(const bool p_edited) { _edited = p_edited; }
	bool is_edited() const { return _edited; }
	void set_modified(const bool p_modified) { _modified = p_modified; }
	bool is_modified() const { return _modified; }
	void set_location(const Vector2i &p_location);
	Vector2i get_location() const { return _location; }

	// Utility
	void set_data(const Dictionary &p_data);
	Dictionary get_data() const;
	Ref<Terrain3DRegion> duplicate(const bool p_deep = false);

protected:
	static void _bind_methods();
};

typedef Terrain3DRegion::MapType MapType;
VARIANT_ENUM_CAST(Terrain3DRegion::MapType);
constexpr Terrain3DRegion::MapType TYPE_HEIGHT = Terrain3DRegion::MapType::TYPE_HEIGHT;
constexpr Terrain3DRegion::MapType TYPE_CONTROL = Terrain3DRegion::MapType::TYPE_CONTROL;
constexpr Terrain3DRegion::MapType TYPE_COLOR = Terrain3DRegion::MapType::TYPE_COLOR;
constexpr Terrain3DRegion::MapType TYPE_TEX_ID_A = Terrain3DRegion::MapType::TYPE_TEX_ID_A;
constexpr Terrain3DRegion::MapType TYPE_TEX_ID_B = Terrain3DRegion::MapType::TYPE_TEX_ID_B;
constexpr Terrain3DRegion::MapType TYPE_WEIGHT_A = Terrain3DRegion::MapType::TYPE_WEIGHT_A;
constexpr Terrain3DRegion::MapType TYPE_WEIGHT_B = Terrain3DRegion::MapType::TYPE_WEIGHT_B;
constexpr Terrain3DRegion::MapType TYPE_NORMAL = Terrain3DRegion::MapType::TYPE_NORMAL;
constexpr Terrain3DRegion::MapType TYPE_MAX = Terrain3DRegion::MapType::TYPE_MAX;
constexpr inline const Image::Format *FORMAT = Terrain3DRegion::FORMAT;
constexpr inline const char **TYPESTR = Terrain3DRegion::TYPESTR;
constexpr inline const Color *COLOR = Terrain3DRegion::COLOR;

// Inline functions

inline void Terrain3DRegion::update_height(const real_t p_height) {
	if (p_height < _height_range.x) {
		_height_range.x = p_height;
		_modified = true;
	} else if (p_height > _height_range.y) {
		_height_range.y = p_height;
		_modified = true;
	}
}

inline void Terrain3DRegion::update_heights(const Vector2 &p_low_high) {
	if (p_low_high.x < _height_range.x) {
		_height_range.x = p_low_high.x;
		_modified = true;
	}
	if (p_low_high.y > _height_range.y) {
		_height_range.y = p_low_high.y;
		_modified = true;
	}
}

#endif // TERRAIN3D_REGION_CLASS_H
