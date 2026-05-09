# Depthly

Local macOS split-depth video player MVP.

## What it does

- Opens a local video file via system picker.
- Plays the video locally with `AVPlayer`.
- Overlays a split-depth foreground layer on top of black borders.
- Runs depth estimation locally.
- Compiles without Xcode as a Swift Package Manager project.

## Build

Requires macOS with Swift toolchain installed.

```bash
swift build
```

If you add a compiled Core ML model, place it in the app bundle or wire it into `PlayerViewModel.makeDefaultDepthEstimator()`.

## Architecture

- `DepthlyApp` - SwiftUI entry point.
- `MainView` - main player UI.
- `VideoPlayerContainer` - playback surface and overlay.
- `PlayerViewModel` - state, file loading, playback, effect orchestration.
- `VideoFrameProvider` - `AVPlayerItemVideoOutput` frame sampling.
- `DepthEstimating` - depth estimation protocol.
- `MockDepthEstimator` - fallback local pseudo-depth estimator.
- `CoreMLDepthEstimator` - generic wrapper around a compiled Core ML model.
- `SplitDepthRenderer` - Core Image composition and overlay rendering.
- `EffectSettings` - user-facing effect parameters.
- `PlaybackOutputRouting` - exposes external playback state.

## MVP behavior

- The app uses `MockDepthEstimator` by default.
- The split-depth overlay is rendered with Core Image.
- Mask refresh is throttled so playback stays responsive.
- If no depth map is available, the last valid mask is reused.

## Core ML integration point

The app currently falls back to mock depth. To plug in a real model:

1. Add a compiled `.mlmodelc` to the bundle.
2. Update `PlayerViewModel.makeDefaultDepthEstimator()`.
3. If your model output is not a pixel buffer named `depth`, adjust `CoreMLDepthEstimator`.

## Files

- `Package.swift`
- `Sources/DepthlyApp/App/DepthlyApp.swift`
- `Sources/DepthlyApp/App/PlayerViewModel.swift`
- `Sources/DepthlyApp/App/PlaybackOutputRouting.swift`
- `Sources/DepthlyApp/Depth/*`
- `Sources/DepthlyApp/Rendering/*`
- `Sources/DepthlyApp/Video/*`
- `Sources/DepthlyApp/Views/*`

## Notes

- This is an MVP scaffold, not a finished production renderer.
- AirPlay and custom compositing are intentionally kept loosely coupled because external playback can bypass the local overlay path.
- For production, replace the mock depth path with a lightweight Core ML depth model and consider a Metal renderer.
