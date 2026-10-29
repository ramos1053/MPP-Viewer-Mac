# Building MPP Viewer

The app is two separate builds that have to happen in order: the .NET Helper first, then the Swift app
(which locates the Helper binary at a fixed path relative to its own source, described below).

## Prerequisites

- **macOS**, recent enough to run a current Xcode. Developed against macOS 27.
- **Xcode**, with its command-line tools. Developed against Xcode 27 / Swift 6.4. Install from the App
  Store or [developer.apple.com](https://developer.apple.com/xcode/), then run
  `xcode-select --install` if the command-line tools aren't already present.
- **.NET SDK 9.0**. Install from [dotnet.microsoft.com](https://dotnet.microsoft.com/download). Confirm
  with `dotnet --version`. If `dotnet` isn't on your `PATH` after installing, see TROUBLESHOOTING.md.

No other dependencies are required. Swift packages (none beyond the standard library and system
frameworks) and the one .NET NuGet package (`MPXJ.Net`) are both resolved automatically by their
respective build tools.

## Repository layout

```
MPP-Viewer-Mac/
├── App/                  Swift package — the native UI
│   ├── Package.swift
│   ├── run-dev.sh         dev-loop launcher — use this, not `swift run` (see below)
│   ├── Resources/
│   │   └── AppIcon.icns   app icon, copied into the dev `.app` bundle by run-dev.sh
│   └── Sources/MPPViewerMac/
└── Helper/                .NET console app — file reading/writing via MPXJ.Net
    ├── MppHelper.csproj
    └── Program.cs
```

This layout matters: `App/Sources/MPPViewerMac/AppModel.swift` locates the Helper executable by walking
up from its own source file's path at compile time (`App/Sources/MPPViewerMac` → `App` → repo root →
`Helper/bin/Debug/net9.0/MppHelper`). If you move `App/` and `Helper/` to different parents, or rename
either directory, the Swift app will not find the Helper at its default location — use the
`MPP_HELPER_PATH` environment variable to override it (see below).

## Build the Helper

```
cd Helper
dotnet build
```

This restores `MPXJ.Net` from NuGet and produces `Helper/bin/Debug/net9.0/MppHelper`. Rebuild it whenever
`Helper/Program.cs` changes; the Swift app does not need rebuilding just because the Helper changed, and
vice versa.

## Build the Swift app

```
cd App
swift build
```

This is a plain Swift package build — no Xcode project file, no `.xcodeproj` to open. You can still open
`App/Package.swift` directly in Xcode if you want Xcode's editor/debugger; `swift build`/`swift run` from
the command line work the same either way.

## Run it

```
cd App
./run-dev.sh
```

Use this, not `swift run` or a bare `.build/debug/MPPViewerMac` invocation. `swift run` launches a plain
Mach-O binary with no `.app` bundle and no LaunchServices registration — it never properly becomes "the
active application" at the OS level, so keyboard focus can silently stay with whatever launched it (your
terminal) even though the app's window is frontmost. `run-dev.sh` builds the Swift app, wraps the
resulting binary in a minimal `.app` bundle at `/tmp/MPPViewerMac-dev.app` with its own `Info.plist`, and
launches it with `open`, exactly like a real installed app. It does not rebuild the Helper — build that
separately first (above) and whenever you change it.

To quit and relaunch during development:

```
pkill -f MPPViewerMac
cd App && ./run-dev.sh
```

### Overriding the Helper path

If your checkout doesn't match the default relative layout, or you want to point the app at a different
Helper build (for example, a `Release` build instead of `Debug`), set `MPP_HELPER_PATH` before launching:

```
MPP_HELPER_PATH=/path/to/MppHelper ./run-dev.sh
```

## Building a distributable `.pkg` installer

This produces the same kind of signed `.pkg` published under Releases: a release-configuration app,
code-signed with a Developer ID, with a self-contained Helper bundled inside it (no system .NET
required). It is **not notarized** — see TROUBLESHOOTING.md for what that means for anyone installing it.

1. **Publish the Helper as self-contained**, for the architecture you're targeting (`osx-arm64` for
   Apple Silicon, `osx-x64` for Intel):

   ```
   cd Helper
   dotnet publish -c Release -r osx-arm64 --self-contained true \
     -p:PublishSingleFile=false -o bin/publish/osx-arm64
   ```

   This produces a whole directory (`MppHelper` plus every native library it needs), not a single file —
   `PublishSingleFile` is deliberately left off, since this app needs the directory layout intact to
   code-sign every Mach-O inside it individually (see step 3).

2. **Build the Swift app in release configuration:**

   ```
   cd App
   swift build -c release
   ```

3. **Assemble the `.app` bundle** — `Contents/MacOS/MPPViewerMac` (the release binary),
   `Contents/Resources/AppIcon.icns`, `Contents/Resources/Helper/` (the *entire* publish output
   directory from step 1 — `AppModel.defaultHelperURL()` looks for `Contents/Resources/Helper/MppHelper`
   specifically), and an `Info.plist` with a real `CFBundleIdentifier`, version, and
   `LSMinimumSystemVersion`.

4. **Code-sign everything, inside out** — every Mach-O binary/dylib under `Helper/`, then the main app
   executable, then the bundle itself, each with Hardened Runtime and the same Developer ID Application
   identity throughout (consistent signing across every loaded library is what lets Hardened Runtime's
   library validation pass without needing to disable it):

   ```
   find "MPPViewer.app/Contents/Resources/Helper" -type f \( -perm +111 -o -name "*.dylib" \) -print0 \
     | xargs -0 -I{} codesign --force --timestamp --options runtime \
         --sign "Developer ID Application: <Your Name> (<Team ID>)" "{}"
   codesign --force --timestamp --options runtime \
     --sign "Developer ID Application: <Your Name> (<Team ID>)" "MPPViewer.app/Contents/MacOS/MPPViewerMac"
   codesign --force --timestamp --options runtime \
     --sign "Developer ID Application: <Your Name> (<Team ID>)" "MPPViewer.app"
   codesign --verify --deep --strict --verbose=2 "MPPViewer.app"
   ```

5. **Build and sign the installer package:**

   ```
   pkgbuild --install-location /Applications --component "MPPViewer.app" MPPViewer-component.pkg
   productbuild --package MPPViewer-component.pkg \
     --sign "Developer ID Installer: <Your Name> (<Team ID>)" MPPViewer.pkg
   ```

6. **Do not notarize** (`xcrun notarytool submit` / `stapler staple`) unless that changes — this project
   deliberately ships signed-but-unnotarized. See README.md's Installing section and
   TROUBLESHOOTING.md for the Gatekeeper experience this produces.

List available signing identities with `security find-identity -v -p codesigning` (app) and
`security find-identity -v` (installer — the Developer ID Installer type doesn't show up under the
`codesigning` policy).

## What's not set up yet

- **Notarization.** Deliberate — see above.
- **Continuous integration.** There is no CI configuration in this repository yet.
- **An automated packaging script.** The steps above are currently manual; a `package.sh` that runs them
  in order would be a reasonable addition if this is built often enough to be worth it.

See `TROUBLESHOOTING.md` for build and runtime problems and how to diagnose them.
