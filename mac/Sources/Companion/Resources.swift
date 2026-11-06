import AppKit

/// Sprites and clips: Contents/Resources in the packaged .app, else SwiftPM's bundle (swift run).
func resource(_ name: String, _ ext: String) -> URL? {
  if let u = Bundle.main.url(forResource: name, withExtension: ext) { return u }
  return Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Resources")
}
