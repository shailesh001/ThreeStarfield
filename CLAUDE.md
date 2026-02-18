# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

ThreeStarfield is a native iOS SwiftUI app that renders an interactive 3D starfield visualization using SceneKit. It loads a star catalog from `data.json`, converts celestial coordinates (RA/Dec) to 3D Cartesian positions, and renders stars as spheres with magnitude-based sizing, color, and glow effects.

## Build & Run

- **Build system**: Xcode project (ThreeStarfield.xcodeproj) — no SPM or CocoaPods dependencies
- **Open in Xcode**: `open ThreeStarfield.xcodeproj`
- **Build from CLI**: `xcodebuild -project ThreeStarfield.xcodeproj -scheme ThreeStarfield -sdk iphonesimulator build`
- **Target**: iOS/iPadOS, Swift 5, all orientations supported
- **No tests currently exist**

## Architecture

The app follows **MVVM** with factory and coordinator patterns. Almost all logic lives in a single file:

**`ThreeStarfield/StarfieldViewer.swift`** (~936 lines, organized by `MARK:` sections):

| Section | Purpose |
|---|---|
| `Star` / `StarCatalog` | Codable data models mapping to `data.json` |
| `StarLoader` | Async JSON loading from bundle or URL |
| `CoordinateConverter` | RA/Dec → 3D vector conversion (distance scale factor: 2.0) |
| `StarSizer` | Maps star magnitude to visual sphere radius |
| `Color` extension | Hex color parsing, cross-platform UIColor/NSColor bridging |
| `StarNodeFactory` | Creates SceneKit sphere nodes with glow shells |
| `BackgroundStarFactory` | Particle system (5000 particles) for ambient stars |
| `StarfieldSceneManager` | Manages the SCNScene: camera (z=500), lighting, fog, star loading, settings application |
| `StarfieldViewModel` | ObservableObject with `Settings` struct (6 params: background stars, camera control, fog density, star size scale, zoom level, info panel opacity) |
| `SceneKitViewRepresentable` | UIViewRepresentable bridge with Coordinator for gesture handling (pinch zoom) |
| `StarfieldView` | Main SwiftUI view composing the scene, info panel, and settings panel |
| `StarInfoPanel` / `SettingsPanel` | Overlay UI components |

**Other files:**
- `ThreeStarfieldApp.swift` — App entry point, single WindowGroup with `StarfieldView`
- `ContentView.swift` — Legacy placeholder, unused
- `data.json` — Star catalog with 60 stars (name, type, magnitude, distance, temperature, RA, Dec, hex color)

## Key Implementation Details

- **Cross-platform guards**: Uses `#if canImport(UIKit)` / `#if canImport(AppKit)` for platform colors
- **Settings update guard**: `lastAppliedSettings` comparison prevents redundant scene re-renders
- **Observer cleanup**: NotificationCenter observers are removed in `deinit` to prevent memory leaks
- **Zoom**: Camera moves radially from the origin by scaling its position vector, clamped to 100–1000 range, zoom factor 200.0
- **Communication**: NotificationCenter used for camera control toggle between SwiftUI and SceneKit
