<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-08-10 | Updated: 2026-08-10 -->

# screenshots

## Purpose

The pub.dev gallery images, referenced from `screenshots:` in
`pubspec.yaml`. Unlike the rest of the agent docs, the referenced `.webp`
files **ship in the published package** (pub.dev requires the files inside
the tarball; limit is 5 images, ≤ 4 MB each). The first entry doubles as
the package thumbnail in pub.dev search results.

The images are portrait renders inside an Apple iPhone 17 bezel.

## Key Files

| File | Description |
|------|-------------|
| `munich-liberty-framed.webp` | Munich old town, OpenFreeMap Liberty, zoom 16 |
| `zermatt-hillshade-framed.webp` | Zermatt, Liberty + Esri World Hillshade raster overlay, zoom 14.5 |
| `munich-dark-framed.webp` | Munich old town + Isar, OpenFreeMap Fiord (dark), zoom 15 |

## For AI Agents

### Regenerating the screenshots

They are real renders of `example/` on Flutter web, captured headless with
Playwright and composited into Apple's official product bezel. The whole
pipeline is key-free.

1. **Build the example once**, pointing the style at a file that will be
   swapped per shot, and serve it:

   ```
   cd example && flutter build web --release \
     --dart-define=STYLE_URL=http://localhost:8123/shot-style.json
   python3 -m http.server 8123 -d build/web
   ```

2. **Author one style JSON per shot.** The example reads the initial
   camera from the style's `center`/`zoom`, so each shot is fully defined
   by its JSON — no code changes:

   - *munich-liberty*: `https://tiles.openfreemap.org/styles/liberty`
     with `center: [11.5755, 48.1373]`, `zoom: 16`.
   - *zermatt-hillshade*: Liberty with `center: [7.7445, 46.0125]`,
     `zoom: 14.5`, plus a raster source
     `https://services.arcgisonline.com/arcgis/rest/services/Elevation/World_Hillshade/MapServer/tile/{z}/{y}/{x}`
     (`tileSize: 256`, `maxzoom: 15`) and a `raster` layer
     (`raster-opacity: 0.45`) inserted directly before the first `water*`
     layer.
   - *munich-dark*: `https://tiles.openfreemap.org/styles/fiord` with
     `center: [11.5815, 48.135]`, `zoom: 15`. (OpenFreeMap's `dark`
     style renders too flat for a gallery image; Fiord reads better.)

   For the framed portrait shots, additionally set compact `attribution`
   strings on the sources (`OpenMapTiles © OpenStreetMap`, hillshade
   `Esri`) — the style source's own attribution wins over the TileJSON's,
   `SimpleAttributionWidget` prepends `flutter_map | © `, and the shorter
   line clears the bezel's rounded corner. OpenFreeMap doesn't require
   attribution; OpenMapTiles and OSM do.

3. **Capture with Playwright** (chromium): copy the shot's JSON to
   `build/web/shot-style.json`, open `http://localhost:8123/` in a fresh
   browser context, wait for network idle plus ~15 s settle, then
   screenshot with viewport 603×1367, `deviceScaleFactor: 2` and clip
   `{0, 56, 603, 1311}` (crops the 56 px AppBar) → 1206×2622, the
   iPhone 17's native screen resolution (2× rather than the device's 3×
   keeps labels small and the attribution line short enough).

4. **Bezel**: Apple's official product bezels (Apple Design Resources,
   direct download
   `https://devimages-cdn.apple.com/design/resources/download/Bezel-iPhone-17.dmg`;
   newer devices appear on developer.apple.com/design/resources under
   Product Bezels). `yes | hdiutil attach` past the embedded license,
   take `PNG/iPhone 17/iPhone 17 - Black - Portrait.png` (1350×2760,
   transparent screen cutout of exactly 1206×2622 at (72, 69) — detect it
   by scanning the alpha channel from the image centre outward). Composite
   in a Playwright page: map capture positioned at the cutout, bezel PNG
   on top, screenshot with `omitBackground: true` for transparent
   corners. The map must be clipped by a pixel-exact mask of the screen
   region — flood-fill the bezel's transparent area from the centre and
   invert its edge alpha (CSS `mask-image`). The image corners *outside*
   the shell are transparent too, and the screen cutout is a squircle, so
   an unmasked rectangle pokes out past the shell's rounded corners and a
   CSS `border-radius` approximation clips wrongly. Apple's license permits using the bezels to showcase your
   app; keep the framed shots on the latest-generation device.

5. **Convert**: `cwebp -q 82 -m 6 shot.png -o shot.webp` (alpha is
   preserved) → ~160–500 KB.

### Working In This Directory

- Adding or renaming an image means updating `screenshots:` in
  `pubspec.yaml` and the table above; pubspec descriptions are capped at
  160 characters by pub.dev.
- Keep the first pubspec entry the strongest image — it is the search
  thumbnail.
- Verify with `dart pub publish --dry-run` that exactly the framed
  `.webp` files are in the file list (this `AGENTS.md` must stay
  excluded via `.pubignore`).
