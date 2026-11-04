# RaceFlyover — Technical Architecture

An orientation guide for developers joining the project. It explains what the
system is, how the pieces fit together, and where the non-obvious decisions
live. Read it once end-to-end before touching code; keep it nearby as a map.

## 1. What RaceFlyover is

RaceFlyover is a **macOS screensaver that flies a camera along real marathon
courses** — 14 races including all seven World Marathon Majors. The route is
rendered either over live Apple Maps 3D imagery or over stylized offline
themes, with a HUD showing distance, aid stations, an elevation profile, and a
minimap.

It ships in two forms built from **one shared codebase**:

- `RaceFlyover.saver` — the screensaver bundle installed into
  `~/Library/Screen Savers`.
- `RaceFlyoverPreview.app` — a development/debugging app that runs the same
  view in a normal window, with CLI modes for snapshots, GIFs, and behavioral
  tests.

Requirements: macOS 14+; macOS 26+ enables Liquid Glass HUD panels. Language:
Swift 5.

## 2. Codebase layout

Everything lives under `Sources/`; both targets compile **all** of
`Sources/RaceFlyover/` and differ only in entry point and Info.plist. There is
no separate saver/preview fork of the code.

| Path | Role |
|---|---|
| `Sources/RaceFlyover/RaceFlyoverView.swift` | Screensaver principal class (`ScreenSaverView`). Owns the view stack, drives the frame loop, manages multi-instance/multi-screen behavior, hosts the Options sheet. |
| `Sources/RaceFlyover/FlyoverEngine.swift` | Pure playback/camera brain: phases (intro → running → finish → fadeOut), distance along the course, slow-down "visits" at landmarks and stations, chase/north-up/overview camera math, multi-screen sync. Renderers only *read* from it. |
| `Sources/RaceFlyover/Course.swift` | `CourseData` (Codable JSON on disk) → `Course` runtime model: local metric coordinates, cumulative distance, elevation profile, official-km scaling. |
| `Sources/RaceFlyover/Settings.swift` | All user-facing option enums, the `Config` struct, `ScreenSaverDefaults` persistence, and `CourseLibrary` (loads bundled course JSON, majors/selection logic). |
| `Sources/RaceFlyover/MapFlyoverView.swift` | Live 3D Apple Maps path: wraps `MKMapView`, sets the camera per frame, draws pin/ghost layers above the map, compensates MapKit's camera latency. |
| `Sources/RaceFlyover/TileGround.swift` | Flat Apple Maps fallback: snapshot tile cache (`AppleMapTiles`) and `TileGroundView`, which places Web Mercator tiles as CALayers under projective 3D transforms. |
| `Sources/RaceFlyover/StylizedView.swift` | Self-contained software renderer: pinhole `Projector`, ground grid, route as a 3D polyline with an elevation "curtain", pins, stations — all Core Graphics. |
| `Sources/RaceFlyover/HUDOverlay.swift` + `HUDRenderer.swift` | HUD compositor and drawing. The HUD is split into small per-part layer-backed views (title, metrics, profile, cards) plus Liquid Glass panels on macOS 26. |
| `Sources/RaceFlyover/RouteOverlay.swift` | `MKOverlay` + renderer that draws the route *inside* MapKit tiles so buildings occlude it correctly. |
| `Sources/RaceFlyover/Landmarks.swift` / `AreaNamer.swift` | MapKit lookups: landmark resolution via `MKLocalSearch` (disk-cached, rate-limited) and the reverse-geocoded neighborhood caption. |
| `Sources/RaceFlyover/MapVisibility.swift` | Method swizzling that keeps MapKit rendering in an "occluded" screensaver window (see §7). |
| `Sources/RaceFlyover/ConfigSheetController.swift` | The entire Options sheet UI in code: sidebar + 6 pages, live-apply with Cancel/restore. |
| `Sources/RaceFlyover/Theme.swift` / `Drawing.swift` | Color palettes for the 9 visual styles, and shared Core Graphics drawing helpers. |
| `Sources/RaceFlyover/FrameStats.swift` | Rolling frame timing, logged every 5 s to unified log (`com.raceflyover` / `perf`). |
| `Sources/Preview/main.swift` | Preview app entry point: interactive window plus `--snapshot`, `--gif`, `--list`, `--sync-test`, `--sheet-test` CLI modes. |

Supporting directories:

- `Resources/Courses/*.json` — 19 course data files (see §5).
- `tools/build_courses.py` — generates those files from upstream GPX/GeoJSON.
- `tools/build_installer.sh` — builds the `.pkg` installer.
- `build.sh` — the canonical build script (see §6).
- `xcode/` — XcodeGen spec for the optional Xcode project.
- `docs/` — project history and release notes.

## 3. Frameworks and rendering strategy

The project uses AppKit, ScreenSaver, **MapKit** (MKMapView, MKMapSnapshotter,
MKLocalSearch, reverse geocoding), CoreLocation, QuartzCore/Core Animation,
Core Graphics, and simd.

Notably, it does **not** use SceneKit or SpriteKit. Each rendering path gets
its 3D differently:

1. **Live 3D** (`MapFlyoverView`) — MapKit's own 3D flyover imagery. Used in
   the preview app and modern screensaver hosts.
2. **Flat tiles** (`TileGroundView` + `StylizedView` in tile mode) — Web
   Mercator snapshot tiles placed under projective `CATransform3D` transforms
   that match the stylized projector, so route and pins drawn on top align
   exactly. Forced inside `legacyScreenSaver` (see §7), and used as fallback
   when the live map fails.
3. **Stylized only** — five drawn styles (Midnight, Neon, Daylight, Blueprint,
   Mono) rendered entirely in Core Graphics through a hand-rolled pinhole
   `Projector`.

Metal appears only indirectly: the code heals MapKit's `CAMetalLayer` drawable
sizes when the surface collapses.

## 4. Runtime data flow

### Frame loop

`RaceFlyoverView` drives everything with a `CADisplayLink`
(`preferredFrameRateRange`, macOS 14+). Each tick advances animation to the
link's `targetTimestamp` for even motion; `animateOneFrame()` is the fallback
when no callbacks arrive. Per frame:

1. `engine.step(dt)` — advance phase, distance, and camera (`dt` capped at
   0.25 s).
2. `renderFrame()` — push the camera to the live map, reposition tiles, mark
   the stylized view dirty, refresh the HUD.

### Engine phases

`FlyoverEngine` runs each course as:

- **intro** (~7 s): swoop from overview to chase camera; waits up to 25 s for
  `sceneReady` (map settled + landmarks resolved).
- **running**: speed = course length / configured lap minutes, with eased
  slow-down "visits" at stations and landmarks.
- **finish** (~7 s), then **fadeOut** and on to the next course.

The chase camera's tilt is dynamic, driven by road-straightness and the
building-density profiles baked into the course data.

### HUD

`HUDOverlayView.refresh()` positions small per-part views each frame;
`HUDRenderer` draws into them. The split into many small layers is deliberate
— a single screen-sized transparent layer costs tens of MB per frame at
Retina. Liquid Glass panels (macOS 26+) trail one frame behind via
`GlassPanelsView`.

### Multi-screen

With multiple displays, `DisplayMode` decides behavior: `same` elects the
earliest-serial instance as leader and followers call
`engine.sync(to:lag:)` with drift correction; `mainOnly` idles secondary
screens; `different` runs each independently. `claimScreen`/`retire` ensure
only the newest view per screen renders.

## 5. Course data pipeline

Course files are bundled JSON (`Resources/Courses/*.json`), schema defined by
`CourseData` in `Sources/RaceFlyover/Course.swift`. Each contains:

- metadata (id, name, city, country, month, major status);
- `points` as `[lat, lon, ele]`, evenly resampled every **25 m** and scaled to
  exactly 42.195 km;
- `stations` (km mark, fluid/fuel type, label);
- optional `landmarks` (names resolved at runtime via `MKLocalSearch`);
- `density`/`tall` building profiles every ~300 m (drive automatic camera
  tilt);
- `tunnels` (route segments drawn dashed);
- `flyover: false` for cities without Apple Maps 3D buildings (hidden until
  the "back roads" easter egg unlocks them).

**Generation:** `tools/build_courses.py` downloads GeoJSON/GPX from the
`distanzrunning/gpx` repo and GoAndRace (cached in `build/src`), resamples,
smooths elevation, applies hand-tuned bridge-deck corrections (the source DEM
reads water level under bridges), classifies station waypoints by keyword, and
queries the Overpass API for building density. To add a race: edit the
`COURSES` list in the script, run it, rebuild. `tools/route_viewer.py`
generates a Leaflet HTML page for visually checking routes and stations.

**Runtime loading:** `CourseLibrary.all(settings:)` (Settings.swift) reads the
bundled JSON files. Runtime caches (not bundled) live in
`~/Library/Caches/RaceFlyoverAppleMaps` (tile snapshots) and
`~/Library/Caches/RaceFlyoverLandmarks`.

## 6. Build and release

- **`build.sh`** — the canonical build. It invokes raw `swiftc` twice (arm64 +
  x86_64) and `lipo`, then assembles bundles by hand. The saver is compiled
  `-parse-as-library -bundle` with `Resources/Info.plist`; the preview app
  uses the same sources plus `Sources/Preview/main.swift` with an Info.plist
  generated by `sed` from the saver's. Versions are stamped via `plutil` from
  `git describe`. Subcommands: `install` (copies to `~/Library/Screen Savers`
  and restarts the screensaver daemons), `preview`, `release` (zip).
- **`tools/build_installer.sh`** — `pkgbuild` → `build/RaceFlyover-<version>.pkg`
  installing to `/Library/Screen Savers`, with a postinstall that restarts the
  daemons; optional Developer ID signing.
- **`.github/workflows/installer.yml`** — on `v*` tags: build, optional cert
  import, pkg, attach to the GitHub release. See `docs/RELEASING.md`.
- **`RaceFlyoverPreview.xcodeproj`** — dev/debug convenience only, generated
  from `xcode/project.yml` via `xcode/generate_xcodeproj.sh` (XcodeGen). The
  scheme passes `--course berlin --style satellite --progress 0.3`.

## 7. Gotchas — read before your first PR

1. **Two host environments behave differently.** In `legacyScreenSaver` a live
   MKMapView can report fully loaded yet composite nothing; the code detects
   the process name and uses snapshot tiles there
   (see `docs/screensaver-map-background-fix.md`). "Works in preview" does not
   imply "works installed" — always test the installed saver.
2. **Method swizzling.** `MapVisibility.swift` swizzles `occlusionState` on
   NSWindow/NSApplication so MapKit renders in a window that claims to be
   occluded. If visibility behavior looks impossible, start here.
3. **Instance lifecycle is adversarial.** The screensaver host creates extra
   `RaceFlyoverView` instances and leaks old ones; `claimScreen`/`retire`/
   `reapOrphans` and the weak `instances` table exist because of this. The
   Options sheet is a single shared window per process for the same reason.
4. **Coordinate systems abound.** Course-local metric frame (x east / y north,
   equirectangular around the centroid), MapKit points, Web Mercator tiles,
   and three camera models (engine `CameraState`, stylized `Projector`,
   MapKit's camera). Traced metres ≠ official kilometres — GPS traces run
   long, so use `Course.officialKm`/`along` to convert.
5. **MapKit latency compensation is load-bearing.** MapKit displays the camera
   ~25 ms late, so overlays are aligned per frame with a homography fitted to
   probe points plus a `TerrainCamera` correction in
   `MapFlyoverView.makeProjection`. Do not "simplify" it.
6. **No test suite.** Verification goes through the preview app's CLI modes
   (`--sync-test`, `--sheet-test`, `--snapshot`, `--gif`) and unified-log
   diagnostics:
   `log show --predicate 'subsystem == "com.raceflyover"'` (categories `map`,
   `perf`, `landmarks`).
7. **Frame pacing.** Drive animation from the display link's
   `targetTimestamp`, not callback time; `dt` is capped at 0.25 s and adaptive
   FPS can drop 60 → 30.
8. **HUD layering is performance-sensitive.** Preserve the small-per-part
   layer pattern in `HUDOverlay.swift`; a full-screen transparent layer is a
   regression.
9. **Bundle metadata has multiple sources of truth.** `Resources/Info.plist`
   (saver), `Resources/Info-Preview.plist` (Xcode project), and build.sh's
   `sed`-derived plist can diverge — check all three when changing bundle
   metadata.
10. **Regenerating the Xcode project loses scheme run arguments** — see the
    caveat in `docs/xcode-project-fix.md`.
11. **Course data licensing.** The upstream GPX repo states no licence; check
    before redistributing generated course files.

## 8. Where to go next

- Run the preview app: `./build.sh preview` (or `⌘R` in the Xcode project).
- Watch it log: `log stream --predicate 'subsystem == "com.raceflyover"'`.
- Adding a course: `tools/build_courses.py` and §5 above.
- Cutting a release: `docs/RELEASING.md`.
