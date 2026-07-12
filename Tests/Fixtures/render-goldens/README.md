# Menu-bar render goldens (pixel parity, package 4a)

These fixtures pin the **pre-package-4a** `StatusRenderer` output, captured while
`Sources/StatusRenderer.swift` was at commit **`00c7d6a`** ("Codex sessions:
interactive rows + exec summary"), before any package-4a rendering change.

The package-4a work adds new, dormant rendering parameters (a `provider` and
`role` on the color resolver, glyph pip / "Both" / dashed-track variants, and the
`ColorMode.claude` -> `.brand` rename). Dormancy means every existing call site
must produce **pixel-identical** output. `RenderDormancyParityTests` re-renders
each cell below through the post-4a renderer and asserts RGBA equality within a
+/-1/255 per-channel tolerance.

## What the grid covers

`styles x modes x values x appearances`:

- **styles (4):** `concentric`, `single`, `bars` (drawn via
  `StatusRenderer.image`), `percentages` (rasterized from
  `StatusRenderer.percentText`).
- **modes (5):** `brand`, `thresholds`, `monochrome`, `heatmap`, `accent`.
  The stable key `brand` maps to `ColorMode.claude` pre-4a and `ColorMode.brand`
  post-4a (see `colorMode(forKey:)` in `Tests/RenderParitySupport.swift`).
- **values (8):** `(five, week, projected)` tuples straddling both threshold
  edges (70 and 90) on both windows, plus the red >=90 override, the projected
  ghost arc, genuine zero, and the nil-window paths. See `renderGoldenValues`.
- **appearances (2):** `aqua` and `darkAqua`, pinned at draw time.

4 x 5 x 8 x 2 = **320 cells**, one `.rgba` file each (~1.6 MB total).

## Rendering method (the parity contract [R4])

For each cell: pin the `NSAppearance` (`aqua` / `darkAqua`) via
`performAsCurrentDrawingAppearance`, draw at a **fixed 1x scale** into an
**explicit sRGB `CGContext`** (8-bit, premultiplied-last), and store the **raw
RGBA bytes**. Never a TIFF/PNG container. Text (percentages) is rasterized onto a
fixed 100x18 canvas with the app's menu-bar font.

## File format

`<cell-id>.rgba`: an 8-byte little-endian header (`width`, `height` as `UInt32`)
followed by `width * height * 4` raw RGBA bytes. Cell id:
`<style>_<mode>_f<five>_w<week>_p<projected>_<aqua|dark>` (`nil` for absent
values).

## Regenerating (only intentionally, from the pinned renderer)

    CAPTURE_RENDER_GOLDENS=1 swift test --filter RenderGoldenCaptureTests

An ordinary `swift test` **never** rewrites these (the capture test is skipped
without the env var), so the parity test always compares new code against the
frozen pre-4a pixels. Determinism was verified by capturing twice and confirming
a byte-identical directory (`diff -rq`), and that aqua vs darkAqua and the
color modes each produce distinct pixels.
