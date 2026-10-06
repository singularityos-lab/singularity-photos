# Singularity Photos

> [!IMPORTANT]
> Report bugs and request features in the
> [Singularity Desktop tracker](https://github.com/singularityos-lab/singularity-desktop/issues/new/choose).

Photo viewer for the Singularity Desktop.

## Edit mode

Open a photo and choose Edit (Ctrl+E). Edits are non-destructive: the
original file is never rewritten. Raw photos open in the same editor.

- Adjust: a histogram, then Light (exposure in stops, contrast, highlights,
  shadows, whites, blacks, brightness), Color (white balance with an
  eyedropper, temperature in Kelvin for raw photos, vibrance, saturation, color
  or black and white, creative profiles, `.cube` look tables) and Presence
  (texture, clarity, dehaze). Tone Curve, Color Mixer, Color Grading, Detail
  (sharpening, luminance and color noise reduction, a 100% loupe), Lens
  Corrections, Effects (post crop vignette, grain), Calibration and Soft
  Proofing are collapsed sections; the ones you open stay open. Double-click a
  slider name to reset it.
- Filters and Presets: the filters, built-in and saved presets with an amount
  slider, import of Lightroom and Camera Raw `.xmp` presets, and copy or paste
  of chosen settings groups (Shift+Ctrl+C, Shift+Ctrl+V).
- Crop and Geometry: aspect ratios, rotate, flip, straighten, Upright (auto,
  level, vertical, full) and manual perspective, rotation, aspect, scale and
  offsets.
- Masks: brush, linear and radial gradients, color and luminance ranges, sky
  and subject, combined with add, subtract and intersect, each with its own
  local adjustments. Press O to show the mask overlay.
- Spot Removal: heal, clone and remove, with an automatic source you can move.
- History and Snapshots: every step can be revisited; snapshots keep named
  versions.
- Auto Enhance, Compare (the backslash key) and undo/redo work as before. Done saves, Save as
  Copy writes a new file, Revert to Original removes every edit.

Markup stays a separate mode for annotations and uses the same floating
toolbar style.

### Edit file format

Edits live in a JSON sidecar next to the photo, named `.<file name>.edit.json`
(for `beach.jpg`, `.beach.jpg.edit.json`); a virtual copy uses
`.<file name>.<copy id>.edit.json`. When the folder is not writable the
sidecar goes to `$XDG_DATA_HOME/singularity-photos/edits/<sha256 of the URI>.json`.

```json
{
  "version" : 2,
  "rotation" : 90,
  "flip" : false,
  "straighten" : -2.5,
  "crop" : [0.1, 0.05, 0.8, 0.9],
  "levels" : [0.02, 0.97],
  "filter" : "vivid",
  "adjust" : { "exposure" : 0.25, "shadows" : 0.3, "clarity" : 0.2 },
  "develop" : {
    "wb.mode" : "custom", "wb.temperature" : 5200,
    "hsl.sat.blue" : -0.2, "grading.shadows.hue" : 210,
    "curve.master" : [[0.25, 0.2], [0.75, 0.8]]
  },
  "locals" : [ {
    "id" : "...", "name" : "Sky", "enabled" : true, "amount" : 1,
    "adjust" : { "exposure" : -0.7 },
    "mask" : [ { "kind" : "linear", "mode" : "add", "invert" : false,
                 "geometry" : { "x0" : 0.5, "y0" : 0.1, "x1" : 0.5, "y1" : 0.5 } } ]
  } ],
  "spots" : [ { "mode" : "heal", "x" : 0.3, "y" : 0.4, "source_x" : 0.35,
                "source_y" : 0.4, "radius" : 0.02, "feather" : 0.5, "opacity" : 1 } ],
  "snapshots" : [ { "name" : "Before", "time" : 1790000000, "params" : "{...}" } ],
  "history" : [ { "name" : "Exposure", "time" : 1790000000, "params" : "{...}" } ]
}
```

- `rotation` is a multiple of 90, clockwise. `flip` mirrors horizontally
  after the rotation, `straighten` is in degrees and the photo is scaled so no
  empty corners show.
- `crop` is x, y, width and height as fractions of the rotated and
  straightened photo.
- `levels` are the black and white points, 0 to 1.
- `adjust` values go from -1 to 1 (sharpness from 0 to 1, exposure from -2.5
  to 2.5 where 1 is two stops); missing keys are 0. Keys: exposure,
  brightness, contrast, highlights, shadows, whites, blacks, saturation,
  vibrance, warmth, tint, texture, clarity, dehaze, sharpness, vignette.
- `develop` holds every other setting by name (white balance, tone curve,
  color mixer `hsl.<hue|sat|lum>.<band>` and `bw.<band>`, color grading,
  detail, lens corrections, transform, effects, calibration, profile, look
  table). Missing keys keep their default. `curve.<channel>` is a list of
  points from 0 to 1.
- `locals` and `spots` use coordinates from 0 to 1 of the unrotated,
  uncropped photo, so they stay on the subject when the crop changes.
- `filter` is one of `none`, `vivid`, `warm`, `cool`, `fade`, `dramatic`,
  `mono`, `noir`, `sepia`.

Version 1 files are read unchanged. Readers ignore unknown keys and refuse a
newer `version`. The rendered result is cached in
`$XDG_CACHE_HOME/singularity-photos/edited/` and rebuilt when the photo or the
sidecar changes.

### XMP sidecars

When Write XMP Sidecars is on (the default), saving also writes
`<file stem>.xmp` next to the photo, readable by Lightroom, Camera Raw and
other programs. The Camera Raw names are used where the settings match: basic
tone and presence (`crs:Exposure2012` in stops, `crs:Contrast2012` and the
others from -100 to 100), white balance, point and parametric curves, HSL,
gray mixer, color grading, detail, lens corrections, perspective, post crop
vignette, grain, calibration, crop, linear and radial gradients and brush
masks, and spot retouching. The complete edit is also stored as JSON in
`sinty:Develop`, so nothing is lost when a photo is opened again here. A photo
that only has a Camera Raw `.xmp` opens with those settings.

### Processing

The preview and the export run the same floating point pipeline on worker
threads, in linear light with Rec. 2020 primaries, through the shared
`Singularity.Imaging` engine of libsingularity: raw white balance and camera
matrix, lens corrections, spot removal, geometry, noise reduction, dehaze,
local tone, the tone and color stages, masks, sharpening and effects. The
preview works on a copy of at most 1600 pixels per side and caches each stage,
the export on the full photo. Color management uses lcms2: the display
profile and soft proofing with any ICC profile. The pipeline is deterministic
and covered by tests (`meson test develop crs edit`). The GPU is not used yet;
every stage is a separate function so a compute path can replace it.

### Raw sample tests

`meson test raw-samples` develops one photo each from Canon (CR2, CR3), Nikon,
Sony, Fujifilm, Olympus and Panasonic when the samples are available. They
are public domain files from raw.pixls.us, downloaded and checked by
`tests/fetch-raw-samples.sh DIR`; point `SINGULARITY_PHOTOS_RAW_SAMPLES` at
that folder. Without it the tests are skipped.

### For distributors

The editor needs GTK, gdk-pixbuf, json-glib, libxml2, zlib, sqlite and, through
libsingularity, lcms2. Raw photos other than DNG are decoded with LibRaw, which
is loaded at run time when present (`libraw_r`): install it to enable them.

## Requirements

- [Meson](https://mesonbuild.com/) >= 0.59
- [Vala](https://vala.dev/) compiler
- [Vetro](https://github.com/singularityos-lab/vetro/) compiler
- GTK4, libgee-0.8, json-glib
- [libsingularity](https://github.com/singularityos-lab/libsingularity)

## Build & Install

```sh
meson setup build
meson compile -C build
meson install -C build
```

## License

GPL-3.0-only, see [LICENSE](LICENSE).

## Use of Generative AI

Maintainers may use generative AI tools as assistants while working on singularity-photos. Non-trivial assisted commits disclose the tool, model, and scope of the work.

AI tools may assist with code comments, documentation, repetitive code, and issue triage. Maintainers make project decisions and review every assisted change before it is merged.

Use these trailers for non-trivial assisted commits:

```plain
Assisted-by: <tool>:<model-version>
AI-Scope: <what the tool generated and the prompt or a short prompt summary>
```

Single-line completions, renames, and formatting changes do not need trailers.

Coding agents must also follow [AGENTS.md](AGENTS.md) before changing files,
creating commits, or opening pull requests.
