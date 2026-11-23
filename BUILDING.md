# Building MPP Viewer

The app is two separate builds that have to happen in order: the .NET Helper first, then the Swift app
(which locates the Helper binary at a fixed path relative to its own source, described below).

## Prerequisites

- **macOS**, recent enough to run a current Xcode. Developed against macOS 27.
- **Xcode**, with its command-line tools. Developed against Xcode 27 / Swift 6.4. Install from the App
  Store or [developer.apple.com](https://developer.apple.com/xcode/), then run
  `xcode-select --install` if the command-line tools aren't already present.
- **.NET SDK 10.0** (the Helper targets `net10.0`). Install from [dotnet.microsoft.com](https://dotnet.microsoft.com/download). Confirm
  with `dotnet --version`. If `dotnet` isn't on your `PATH` after installing, see TROUBLESHOOTING.md.

No other dependencies are required. Swift packages (none beyond the standard library and system
frameworks) and the one .NET NuGet package (`MPXJ.Net`) are both resolved automatically by their
respective build tools.

## Repository layout

```
MPP-Viewer-Mac/
├── package.sh            builds one architecture's .app (and .pkg) — see the packaging section
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
`Helper/bin/Debug/net10.0/MppHelper`). If you move `App/` and `Helper/` to different parents, or rename
either directory, the Swift app will not find the Helper at its default location — use the
`MPP_HELPER_PATH` environment variable to override it (see below).

## Build the Helper

```
cd Helper
dotnet build
```

This restores `MPXJ.Net` from NuGet and produces `Helper/bin/Debug/net10.0/MppHelper`. Rebuild it whenever
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

## Run the scheduler tests

```
cd App
swift test
```

The Swift Testing suite in `App/Tests/MPPViewerMacTests` checks dependency scheduling and critical
paths using fixed UTC dates. It does not launch the app, start the .NET Helper, or open project files.
To run only this suite, use `swift test --filter SchedulerTests`.

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

Releases ship one installer per architecture: `arm64` (Apple Silicon) and `x64` (Intel). Each is a
release-configuration app, code-signed with a Developer ID, with a self-contained Helper for that
architecture bundled inside it (no system .NET required). It is **not notarized** — see
TROUBLESHOOTING.md for what that means for anyone installing it.

The `package.sh` script runs every step below for one architecture:

```
./package.sh arm64 0.1.3 4     # version, then build number
./package.sh x64   0.1.3 4
```

Output goes to `dist/<arch>/MPPViewer.app`. The app version and build number come from the arguments. Set `APP_SIGN_ID` (a "Developer ID Application" identity) to
sign with Hardened Runtime; without it the app is only ad-hoc signed, which is fine for local testing.
Typical release invocation:

```
APP_SIGN_ID="Developer ID Application: <Your Name> (<Team ID>)" \
INSTALLER_SIGN_ID="Developer ID Installer: <Your Name> (<Team ID>)" \
./package.sh x64 0.1.3 4
```

Set `INSTALLER_SIGN_ID` (a "Developer ID Installer" identity) to also produce
`dist/MPPViewer-<version>-macOS-<arch>.pkg`. The script ends by launching the bundled Helper and
checking it answers; on Apple Silicon the `x64` Helper runs under Rosetta 2 for that check.

Either architecture can be built from either kind of Mac: `dotnet publish -r osx-x64` and
`swift build --arch x86_64` both cross-compile on Apple Silicon. Swift may warn that the x86_64
architecture is deprecated for newer deployment targets; that is expected and does not affect the build.

The manual steps, if you want to do them by hand (shown for arm64; use `osx-x64`, `--arch x86_64` and
`x64` for Intel):

1. **Publish the Helper as self-contained** for the architecture you're targeting:

   ```
   cd Helper
   dotnet publish -c Release -r osx-arm64 --self-contained true \
     -p:PublishSingleFile=false -o bin/publish/arm64
   ```

   This produces a whole directory (`MppHelper` plus every native library it needs), not a single file —
   `PublishSingleFile` is deliberately left off, since this app needs the directory layout intact to
   code-sign every Mach-O inside it individually (see step 4).

2. **Build the Swift app in release configuration** for the same architecture:

   ```
   cd App
   swift build -c release --arch arm64
   ```

3. **Assemble the `.app` bundle** — `Contents/MacOS/MPPViewerMac` (the release binary),
   `Contents/Resources/AppIcon.icns`, `Contents/Resources/Helper/` (the *entire* publish output
   directory from step 1 — `AppModel.defaultHelperURL()` looks for `Contents/Resources/Helper/MppHelper`
   specifically), and an `Info.plist` with a real `CFBundleIdentifier`, version, and
   `LSMinimumSystemVersion`. Never mix architectures: an arm64 app must carry the arm64 Helper and an
   Intel app the x64 Helper (`lipo -archs` on both should agree).

4. **Code-sign everything, inside out** — every Mach-O binary/dylib under `Helper/`, then the main app
   executable, then the bundle itself, each with Hardened Runtime and the same Developer ID Application
   identity throughout (consistent signing across every loaded library is what lets Hardened Runtime's
   library validation pass without needing to disable it) — **except `MppHelper` itself**, which needs
   one extra entitlement (`Helper/entitlements.plist`, already in the repo):

   ```xml
   <?xml version="1.0" encoding="UTF-8"?>
   <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
   <plist version="1.0">
   <dict>
       <key>com.apple.security.cs.allow-jit</key><true/>
       <key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/>
   </dict>
   </plist>
   ```

   **Why**: .NET's CoreCLR JIT-compiles at startup, which needs executable+writable memory pages —
   something Hardened Runtime blocks by default. Without this entitlement, `MppHelper` gets killed the
   instant it tries to start (`Failed to create CoreCLR, HRESULT: 0x80070008`, exit code 137/SIGKILL),
   and the app shows "Helper process closed its output unexpectedly" with no further detail. This never
   shows up running the dev build (`run-dev.sh` never applies Hardened Runtime at all), only once the
   Helper is actually signed for distribution — confirmed the hard way, by shipping v0.1.0 without it.

   ```
   find "MPPViewer.app/Contents/Resources/Helper" -type f \( -perm +111 -o -name "*.dylib" \) \
       ! -name "MppHelper" -print0 \
     | xargs -0 -I{} codesign --force --timestamp --options runtime \
         --sign "Developer ID Application: <Your Name> (<Team ID>)" "{}"
   codesign --force --timestamp --options runtime \
     --entitlements Helper/entitlements.plist \
     --sign "Developer ID Application: <Your Name> (<Team ID>)" \
     "MPPViewer.app/Contents/Resources/Helper/MppHelper"
   codesign --force --timestamp --options runtime \
     --sign "Developer ID Application: <Your Name> (<Team ID>)" "MPPViewer.app/Contents/MacOS/MPPViewerMac"
   codesign --force --timestamp --options runtime \
     --sign "Developer ID Application: <Your Name> (<Team ID>)" "MPPViewer.app"
   codesign --verify --deep --strict --verbose=2 "MPPViewer.app"
   ```

   Before packaging, actually run the signed Helper directly and confirm it responds — don't rely on
   `codesign --verify` alone, since a valid signature says nothing about whether Hardened Runtime will
   let the process actually execute:

   ```
   echo '{"id":1,"command":"new"}' | "MPPViewer.app/Contents/Resources/Helper/MppHelper"
   ```

   A healthy response looks like `{"id":1,"ok":true,"result":{...}}`. If it prints a CoreCLR error and
   exits 137 instead, the entitlement above didn't make it onto `MppHelper`'s signature.

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
- **Native Intel testing.** The x64 build is checked under Rosetta 2 only; it hasn't been run on Intel hardware.

See `TROUBLESHOOTING.md` for build and runtime problems and how to diagnose them.
