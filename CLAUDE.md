# tcam_mac

A native macOS app for browsing and playing Tesla dashcam footage (TeslaCam). Built with SwiftUI, targeting macOS.

## Project Structure

```
tcam_mac/
├── tcam_macApp.swift       # @main entry point, sets min window size (980×680)
├── ContentView.swift       # Root view: folder picker, clip grid, section nav
├── VideoPlayerView.swift   # Full-featured video player with multi-cam support
├── DesignSystem.swift      # Layout constants and animation presets
├── TeslaSEIParser.swift    # Parses SEI NAL units from MP4s to extract telemetry
├── dashcam.proto           # Protobuf schema for SeiMetadata (telemetry per frame)
└── dashcam.pb.swift        # Generated Swift protobuf bindings (do not edit manually)
```

## Architecture

### Data Flow
1. User selects a TeslaCam root folder via `NSOpenPanel`
2. `TeslaCamParser` scans `SavedClips/`, `SentryClips/`, and `RecentClips/` subdirectories
3. MP4 filenames are parsed for timestamps and camera channel names → grouped into `TeslaMoment` (all cameras at one timestamp) → grouped into `TeslaClip` (an event)
4. `ContentView` displays clips in a `LazyVGrid` by section (`SidebarSection`)
5. Tapping a clip navigates to `VideoPlayerView`

### Key Models (defined in ContentView.swift)
- `SidebarSection` — `.saved`, `.sentry`, `.recent`
- `CameraChannel` — `.front`, `.back`, `.left_repeater`, `.right_repeater`, `.left_pillar`, `.right_pillar`
- `TeslaMoment` — a single timestamp with a map of `CameraChannel → URL`
- `TeslaClip` — an event with sorted moments, duration, thumbnail, and metadata

### VideoPlayerView Features
- **View modes**: Front only, Front Focused, 4-Cam grid, All-Cam grid
- **Playback speeds**: 0.5×, 1×, 2×, 4×
- **Telemetry HUD**: draggable overlay showing speed, gear, steering, blinkers, autopilot state — driven by `TeslaSEIParser`
- **Live map**: `MKMapView` with GPS trail pre-computed from SEI data, animated at 15fps
- **Speed graph**: `SpeedGraphView` showing vehicle speed across the clip timeline
- **Sync timers**: three `Timer.publish` streams (telemetry @ 0.2s, sync @ 0.25s, map @ 1/15s)

### Telemetry Pipeline
- `TeslaSEIParser` reads raw H.264 SEI NAL units (type 6) from MP4 sample buffers via `AVAssetReader`
- Payload is extracted and decoded as a Protobuf `SeiMetadata` message (see `dashcam.proto`)
- Fields: `vehicle_speed_mps`, `gear_state`, `steering_wheel_angle`, `blinker_on_left/right`, `brake_applied`, `autopilot_state`, `latitude_deg`, `longitude_deg`, `heading_deg`, linear accelerations, `frame_seq_no`
- Supports both length-prefixed NAL format (AVCC) and Annex B start-code format, with emulation-prevention byte stripping

## Design System (DesignSystem.swift)

### Layout Constants (`enum Layout`)
| Constant | Value | Purpose |
|---|---|---|
| `pagePadding` | 24pt | Outer page margins |
| `cardPadding` | 12pt | Inside card padding |
| `gridSpacing` | 20pt | Gap between grid cards |
| `teslaAspect` | 1448/938 ≈ 1.544 | Native Tesla video aspect ratio |
| `gridCellSpacing` | 2pt | Pixel-aligned spacing in multi-cam grids |

### Animation Presets (`extension Animation`)
- `.ui` — spring(response: 0.38, dampingFraction: 0.82) — navigation, section switches
- `.hover` — spring(response: 0.28, dampingFraction: 0.68) — hover states, button presses
- `.mapFrame` — linear(duration: 1/15) — GPS map updates at 15fps

## Dependencies

- **SwiftUI** + **AppKit** — UI
- **AVFoundation** / **AVKit** — video playback and thumbnail generation
- **MapKit** — live GPS map
- **Combine** — timer publishers for playback sync
- **SwiftProtobuf** — decoding `SeiMetadata` from SEI payloads (package dependency)

## Build & Run

Open `tcam_mac.xcodeproj` in Xcode. No CLI build is configured. The app requires macOS (uses `NSOpenPanel`, `NSImage`, `AppKit`).

If `dashcam.proto` changes, regenerate `dashcam.pb.swift` with:
```sh
protoc --swift_out=. tcam_mac/dashcam.proto
```

## Key Conventions

- All animations use the presets in `DesignSystem.swift` (`.ui`, `.hover`, `.mapFrame`) — don't introduce inline animation values
- The Tesla video aspect ratio is always `Layout.teslaAspect` (1448/938) — don't hardcode aspect ratios elsewhere
- `TeslaSEIParser` is a `final class` with only `static` methods — keep it stateless
- `dashcam.pb.swift` is generated code — never edit it manually; edit `dashcam.proto` and regenerate
- Thumbnail loading is async via `Task.detached(priority: .utility)` in `ClipThumbnailView` — keep thumbnail work off the main thread
- Duration resolution is cached in `TeslaCamParser.DurationResolver` — don't call `AVURLAsset.load(.duration)` redundantly
