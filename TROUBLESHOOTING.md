# Troubleshooting

## Build problems

### `dotnet: command not found`

The .NET SDK installer doesn't always add `dotnet` to your shell's `PATH` automatically, particularly on
zsh. Confirm it's actually installed and find it with:

```
ls ~/.dotnet/dotnet 2>/dev/null || ls /usr/local/share/dotnet/dotnet 2>/dev/null
```

Add whichever directory you find it in to your `PATH` (in `~/.zshrc` or equivalent), then open a new
shell and confirm with `dotnet --version`.

### The Helper launches but the app shows a "Could not launch helper" error

This is almost always `Process.environment["DOTNET_ROOT"]` in `App/Sources/MPPViewerMac/HelperProcess.swift`
pointing at the wrong place. The dev build is framework-dependent — its apphost needs `DOTNET_ROOT` set to
find your installed .NET runtime at launch, separately from whatever let `dotnet build` work in the first
place — and that path is currently hardcoded to `~/.dotnet`. If your .NET SDK is installed somewhere else
(a Homebrew install under `/usr/local` or `/opt/homebrew`, for example), launching the Helper will fail
even though building it succeeded. Either:

- Install the .NET SDK to the default `~/.dotnet` location (the official installer's default), or
- Edit the hardcoded path in `HelperProcess.swift` to match your actual install, or
- Build the Helper as self-contained (`dotnet publish --self-contained`) and point `MPP_HELPER_PATH` at
  the published output — a self-contained apphost doesn't need `DOTNET_ROOT` at all.

### "Cannot find X in scope" errors that don't match reality

SourceKit (the editor's live diagnostics) regularly shows stale "Cannot find type/function in scope"
errors after edits, especially right after the file list changes — these do not reflect real build
failures. The actual compiler (`swift build`) is the only trustworthy signal. If SourceKit stays
persistently wrong even after a successful build, restart it or do a clean rebuild:

```
pkill -f sourcekit
# or
cd App && rm -rf .build && swift build
```

### `swift build` genuinely crashes or hangs on a type-check error

This is a real, reproducible issue with this codebase's size, not just SourceKit noise — it has hit more
than once. Two symptoms seen so far:

- `error: the compiler is unable to type-check this expression in reasonable time; try breaking up the
  expression into distinct sub-expressions` on a large SwiftUI view body or modifier chain.
- `swift-frontend` crashing outright with `failed to produce diagnostic for expression; please submit a
  bug report`, on a long chained-modifier expression.

Both have the same fix: break the offending expression into smaller pieces — intermediate `let` bindings
for one or two modifiers at a time, or pull a large `@ViewBuilder`/`@ToolbarContentBuilder` body out into
multiple smaller computed properties. `ContentView.swift`'s `mainToolbarItems`/`viewToolbarItems` split,
and `TimelineOverviewView.swift`'s `milestone(...)` helper, are both existing examples of code that was
deliberately restructured this way to get past this exact failure — follow the same pattern rather than
inlining everything back together.

### Swift Package Manager can't resolve `platforms: [.macOS(.v26)]`

`Package.swift` requires `swift-tools-version: 6.2` for the `.v26` platform constant to exist at all. If
your installed Swift toolchain predates this, either update Xcode/Swift, or lower both the tools-version
header and the platform constant together — but note the code was written against APIs (`ToolbarSpacer`
among them, even though it's since been removed from active use) that assumed a recent SDK; lowering the
deployment target is not guaranteed to be a no-op.

## Installing the `.pkg`

### macOS says the app "cannot be opened because Apple cannot check it for malicious software" (or similar)

Expected, not a bug — the installer and the app inside it are code-signed with a real Developer ID, but
this project deliberately does not notarize (submit to Apple for automated scanning), so Gatekeeper
still flags a freshly downloaded copy. To open it anyway:

1. Try to open the app once (it will be blocked).
2. Open System Settings ▸ Privacy & Security, scroll down, and look for a line naming the blocked app
   with an "Open Anyway" button next to it. Click it, confirm in the dialog that follows.

If that line never appears, the download is likely still quarantined without having been launched yet —
launch it (or try to) first, then check System Settings again. As a last resort, clear the quarantine
flag directly from Terminal (only do this for a `.pkg`/`.app` you actually trust the source of):

```
xattr -d com.apple.quarantine /path/to/MPPViewer.app
```

### Why this project isn't notarized

A deliberate choice, not an oversight — notarization requires submitting the build to Apple's servers
for every release. The app is still code-signed with a real Developer ID (so its origin is verifiable
and Hardened Runtime is enforced), which is the meaningful security precaution available without that
step.

## Runtime problems

### A file opens with no tasks, or an error banner

This is almost always an unsupported *variant* of a supported extension, not a corrupted file — MPXJ
supports many formats, each with version/dialect quirks it doesn't fully cover. Check the error banner
text at the top of the window for specifics. There is no fallback reader to try.

### Keyboard focus seems to be in the wrong place / arrow keys don't navigate rows

Make sure you launched via `./run-dev.sh`, not `swift run` or the raw binary directly. See "Run it" in
BUILDING.md — a bare Mach-O binary launched outside a real `.app` bundle never properly becomes the
active application at the OS level, and keyboard focus can silently stay with the terminal that launched
it even though the app's window looks frontmost.

### Toolbar display style (Icon Only / Icon and Text) doesn't persist across launches

This was broken once already by removing `.toolbar(id:)` from `ContentView.mainToolbarItems` (see the
toolbar customization note below) and was fixed by having `ContentView` persist the display mode itself,
under its own constant UserDefaults key (`toolbarDisplayModePreference`), on
`NSApplication.didResignActiveNotification`/`.willTerminateNotification` — rather than relying on
AppKit's own autosave, which depends on a *stable* toolbar identifier that only exists when using
`.toolbar(id:)`. If this regresses again, that's the first place to look: confirm the toolbar actually
has a stable identifier before trusting AppKit's own persistence, or keep owning it explicitly as now.

### Do not re-add toolbar customization (drag-to-rearrange, remove buttons, "Customize Toolbar…")

This was implemented once and reliably **crashed the app**. The crash is inside AppKit itself
(`NSToolbarConfigPanel`, via `NSSearchToolbarItemView`'s width-constraint handling while the panel
snapshots the toolbar's search field for its preview) — confirmed via two separate crash reports, from
both the app's own "Customize Toolbar…" command and from macOS's own automatic toolbar right-click menu
item, which appears whenever a toolbar is built with `.toolbar(id:)` regardless of
`allowsUserCustomization`'s value. There is no "disabled but present" middle ground available through
public SwiftUI API that avoids this — the only working fix found was to stop building a customizable
toolbar at all (`ContentView.mainToolbarItems` uses a plain `.toolbar { }`, not `.toolbar(id:)`). If a
future macOS/Xcode release fixes the underlying AppKit bug, that constraint can be revisited — see the
doc comment on `mainToolbarItems` for the full account before touching this again.

### Save doesn't write back to the original file format

This is expected, not a bug — see README.md. Save/Save As always produce Project XML (MSPDI); there is no
writer for `.mpp`, `.gan`, or most other formats this app can read.

### Scheduling (or the critical path) doesn't match Microsoft Project's own calculation

Expected if the project uses holidays or a non-default working week — this app's scheduler
(`App/Sources/MPPViewerMac/Scheduler.swift`) does real forward-pass date cascading and a real
backward-pass critical-path/float calculation, but both use plain calendar-day arithmetic: a fixed
8-hour day, 5-day week, no holidays, no per-resource or per-task working-time calendars. The Calendars
editor (toolbar) saves real calendar data to the file, but the scheduler doesn't consume it yet, so a
project that depends on Microsoft Project's own calendar system will diverge by however many
non-working days fall inside the affected span.

## Where to look next

- **In-app Help** (Help menu, or ⌘?) documents every feature from a user's point of view, including
  known limitations.
- **Source comments** throughout `App/Sources/MPPViewerMac/` are deliberately thorough about *why*
  something is built the way it is, not just what it does — particularly around the toolbar, scheduler,
  and Helper subprocess, which have all had real, non-obvious bugs surface during development. Read the
  doc comment on a function before assuming its current shape is arbitrary.
