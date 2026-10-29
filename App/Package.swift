// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MPPViewerMac",
    // Bumped from .v14 for ToolbarSpacer (fixed/flexible toolbar spacers) — this app only ever
    // runs on the dev machine's own, always-current macOS, so there's no real back-compat cost.
    platforms: [.macOS(.v26)],
    targets: [
        // Tools-version 6.2 is only here for the platforms bump above (needed for `.v26`); keep the
        // actual source compiled in Swift 5 mode so it isn't also opted into Swift 6's strict
        // concurrency checking, which has nothing to do with this change and would ripple across
        // every `Equatable`/closure-capturing view in the app.
        .executableTarget(name: "MPPViewerMac", swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
