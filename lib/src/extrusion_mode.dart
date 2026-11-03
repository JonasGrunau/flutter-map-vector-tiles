/// How `VectorTileLayer` draws `fill-extrusion` layers.
///
/// flutter_map's camera has no pitch, so neither mode tilts the map. The
/// difference is the one MapLibre GL shows with the camera looking
/// straight down:
///
/// | | [perspective] (default) | [flat] |
/// |---|---|---|
/// | Look | roofs lean away from the screen centre, walls show on the side facing it, shaded by the style's `light` | footprints in the extrusion colour, no height |
/// | Where | drawn over the tile images, every frame the map moves | drawn into the tile images |
/// | Per-frame cost | UI-thread work in proportion to the buildings on screen | none |
/// | Above them | labels only — every other layer over an extrusion in the style draws beneath it | the style's own order |
///
/// Patterned extrusions (`fill-extrusion-pattern`) are drawn flat in
/// either mode, and so is everything in `LabelMode.tile`, whose labels
/// are in the tile images the buildings would cover.
enum ExtrusionMode {
  /// 3D buildings, as MapLibre GL draws them at pitch 0: each frame
  /// projects every building on screen through MapLibre's perspective
  /// camera — a roof scales away from the screen centre by
  /// `D / (D − height · pixels per metre)`, `D` being 1.5 viewport
  /// heights — so the lean grows towards the screen edges and with the
  /// zoom, and changes as the map pans. Walls and roofs are shaded with
  /// the style's `light` (MapLibre's default when it has none).
  perspective,

  /// Flat footprints drawn into the tile images, as before 3D buildings
  /// existed: no per-frame cost.
  flat,
}
