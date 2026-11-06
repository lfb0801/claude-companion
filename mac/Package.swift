// swift-tools-version: 6.0
// Native macOS front end for the Claude Code companion: a transparent desktop overlay.
// The Node server in the repository root stays the backend (hooks, prompts, transcripts, tmux).
import PackageDescription

let package = Package(
  name: "Companion",
  platforms: [.macOS(.v14)],
  targets: [
    // Pure logic, no AppKit: physics, targeting, the Intern, stage state, server models.
    .target(name: "StageCore"),
    // The app: overlay window, drawing, sound, server connection, native panels.
    .executableTarget(name: "Companion", dependencies: ["StageCore"], resources: [.copy("Resources")],
                      swiftSettings: [.swiftLanguageMode(.v5)]),
    // Checks for StageCore (swift-testing / XCTest need full Xcode): `swift run StageChecks`.
    .executableTarget(name: "StageChecks", dependencies: ["StageCore"]),
  ]
)
