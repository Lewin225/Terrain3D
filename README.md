# Terrain3D (GodotBryo fork)

This is a patched fork of [Terrain3D](https://github.com/TokisanGames/Terrain3D),
maintained as a vendored git submodule for
[GodotBryo](https://github.com/Lewin225/GodotBryo) — a clean-room Godot 4
reimplementation of Fallout: New Vegas's Gamebryo engine. Base: upstream
`v1.0.2-stable`.

**This fork exists because GodotBryo needs real per-vertex ground-texture data
driven entirely by authored Fallout: New Vegas ESM data (BTXT/ATXT/VTXT), not
Terrain3D's own hand-painted control-map workflow.** Terrain3D's clipmap
mesh/LOD/streaming/collision machinery is used as-is; only its texturing
representation has been replaced.

## What's changed from upstream, in order

1. **Control-map texture-ID field widened 5→6→7 bits** (32→64→128 texture
   slots). GodotBryo's real worldspace ground-texture need (measured directly
   against the shipped game data) exceeded the original 5-bit/32-slot budget.
2. **Real per-vertex N=7 texture-layer format**, replacing Terrain3D's
   competitive 2-texture (base+overlay) control-map blend entirely. Adds new
   per-region map types (`TYPE_TEX_ID_A`/`B`, `TYPE_WEIGHT_A`/`B`,
   `TYPE_NORMAL`) and a real sequential alpha-over compositing shader path,
   so a real cell's full authored layer stack (1 base + up to 6 real ATXT
   overlays, matching the actual FNV ESM data) renders instead of Terrain3D's
   own 2-layer height-blend approximation.
3. **LTEX-identity-preserving grass support.** GodotBryo's real texture pool
   deduplicates ground textures by DDS content (several distinct Fallout
   `LTEX` records share one texture file) — which loses the per-`LTEX`
   identity needed to resolve real `LTEX.GNAM` → `GRAS` grass links. This
   patch keeps the per-vertex ID maps as unique-per-`LTEX` slots and adds a
   small (128-entry) shader-side LUT translating an `LTEX` slot to its
   deduplicated render-texture slot only at the point of albedo/normal
   sampling — so the GPU texture array still benefits from dedup, but a
   GPU-particle grass shader sampling the same per-vertex maps can still
   recover real `LTEX` identity for density/placement filtering.
4. **Fixed terrain-region domain and atomic eight-map publication** for the
   Issue #19 terrain streamer. `Terrain3DData.initialize_fixed_region_domain`
   validates a bounded set of locations, sorts it deterministically by `(y,x)`,
   allocates canonical blank regions, and builds the region map once.
   `publish_region_maps(location, maps)` then accepts exactly the eight staged
   maps for an already-allocated region (height/control as `RF`; the remaining
   maps as `RGBA8`), validates their dimensions and formats, replaces that
   region's maps, and updates its existing array layers and height range. It
   rejects unknown locations and never dirties or emits `region_map_changed`.
   This keeps ordinary streaming publication from triggering Terrain3D's
   global region-map/collision rebuild; camera-local dynamic collision remains
   the caller's explicit responsibility.

## Upstream

For Terrain3D's own documentation, install instructions, and general usage,
see [the real upstream project](https://github.com/TokisanGames/Terrain3D)
and its [readthedocs site](https://terrain3d.readthedocs.io/en/stable/). This
fork is not a general-purpose replacement — it's shaped specifically around
GodotBryo's own real-ESM-data-driven terrain pipeline.
