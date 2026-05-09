# Depthly

Local macOS split-depth video player MVP.

## What it does

- Opens a local video file via system picker.
- Plays the video locally with `AVPlayer`.
- Uses Core Image to present the video and split-depth overlay.
- Runs local foreground estimation with Vision saliency + person segmentation by default.
- Compiles without Xcode as a Swift Package Manager project.

## Build

Requires macOS with Swift toolchain installed.

Command to build:

```bash
swift build
```

If you want a release build:

```bash
swift build -c release
```

If you want to run the app from SwiftPM after building:

```bash
swift run DepthlyApp
```

If you need the binary path after a debug build:

```bash
.build/debug/DepthlyApp
```

If you add a compiled Core ML model, place it in the app bundle or wire it into `PlayerViewModel.loadForegroundModelIfNeeded(force:)`.

### Recommended local model path

Download `DepthAnythingV2SmallF16.mlpackage` from Apple’s Hugging Face repo and place it at:

`Sources/DepthlyApp/Resources/Models/DepthAnythingV2SmallF16.mlpackage`

You can also place models in:

`~/Depthly/Models`

Any additional `.mlpackage`, `.mlmodel`, or `.mlmodelc` files placed in that folder will appear in the in-app model picker.

Then build with:

```bash
swift build
```

Optional override:

```bash
DEPTHLY_MODEL_PATH=/absolute/path/to/DepthAnythingV2SmallF16.mlpackage swift build
```

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
- `MetalSplitDepthRenderer` / `MetalVideoSurface` - Metal-backed presentation layer.
- `EffectSettings` - user-facing effect parameters.
- `PlaybackOutputRouting` - exposes external playback state.

## MVP behavior

- The app uses a local Vision hybrid foreground estimator by default.
- The split-depth overlay is rendered with Core Image.
- Mask refresh is throttled so playback stays responsive.
- If no mask is available, the last valid mask is reused.

## Core ML integration point

The app currently falls back to mock depth. To plug in a real model:

1. Add a compiled `.mlmodelc` or raw `.mlmodel` to the bundle.
2. Select the Core ML option in the in-app picker.
3. If your model output is not a pixel buffer named `predicted_depth`, adjust `CoreMLForegroundMaskEstimator`.

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
