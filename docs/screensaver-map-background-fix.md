# Screen saver map background fix

## Problem

The map background can be visible when Race Flyover runs from Xcode but blank when the same code runs as an installed screen saver. The route, markers, and HUD can still appear because they are drawn separately from the Apple Maps background.

This is not caused by a missing image in the installer. Apple Maps imagery is loaded at runtime rather than bundled in the `.pkg`.

## Why Xcode and the installed screen saver behave differently

Xcode runs Race Flyover in the preview application. That application owns a normal visible window, so its live `MKMapView` can render Apple Maps imagery.

An installed `.saver` bundle is loaded by macOS into Apple's `legacyScreenSaver` process. Its special full-screen window does not always provide a working MapKit rendering surface. MapKit can report that loading finished while its imagery is not composited on screen.

The previous code switched to flat map imagery only after detecting a collapsed Metal surface or a map that never finished loading. A map that reported success without displaying imagery did not trigger that fallback.

## Fix

`Sources/RaceFlyover/RaceFlyoverView.swift` now selects the existing `TileGroundView` renderer immediately when running inside `legacyScreenSaver`.

`TileGroundView` uses `MKMapSnapshotter` to render Apple Maps imagery offscreen. It then displays those images beneath the existing route, markers, and HUD. This path does not depend on the screen-saver host's live MapKit window or Metal surface.

The preview application continues to use live 3D Apple Maps. The installed screen saver uses flat Apple Maps imagery instead of live 3D rendering so that the background remains visible.

## Why this is preferable to a host migration

`legacyScreenSaver` is part of macOS and is not controlled by this project. Rewriting the screen-saver interface or moving away from `ScreenSaverView` would not replace Apple's host for traditional third-party `.saver` bundles.

Using offscreen snapshots is therefore a compatibility solution for the environment in which the installed screen saver actually runs. Live 3D imagery inside that host would require reliable support from Apple or a different product, such as a standalone wallpaper application.

## Verification and release

The source change passed `git diff --check`, and the build and installer shell scripts passed `zsh -n`. A macOS build and an installed-screen-saver runtime test were not available in the Linux development environment.

To verify the fix on macOS:

1. Build a new installer with the GitHub Actions workflow.
2. Install the newly generated `.pkg`; an installer created before this change does not contain the fix.
3. Select an Apple Maps style in Race Flyover's options.
4. Start the full-screen screen saver with an internet connection.
5. Confirm that Apple Maps imagery appears behind the route, markers, and HUD.

The existing Midnight fallback remains in place if Apple Maps imagery cannot be loaded.
