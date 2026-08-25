import Foundation
import IconForge

// Three files, because three things ask for the icon in three shapes. Run from
// the repo root:  swift run --package-path Tools/IconGen IconGen ..
//
// The tile itself - the teal, the squircle, the light and the shadow - comes
// from IconForge, which SwiftProj draws its icon with too. Only the artwork in
// Aperture.swift belongs to this app, which is what makes the two a family.

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")

let shaped = Icon.render(side: 1024, palette: .teal, shaped: true, artwork: iris)
let bleed = Icon.render(side: 1024, palette: .teal, shaped: false, artwork: iris)

// The source scripts/build-app-bundle.sh sips down into the .icns.
try Icon.writePNG(shaped, to: root.appendingPathComponent("icons/AppIcon-1024.png"))

// The Dock icon a plain `swift run` gets, which has no bundle and so no
// Info.plist to name an .icns.
try Icon.writePNG(shaped, to: root.appendingPathComponent(
    "Sources/MacPhotoMaster/Resources/AppIcon.png"))

// iOS is full bleed: the system applies the mask and the shadow itself, and
// would clip a second set of corners off one that arrived with them.
try Icon.writePNG(bleed, to: root.appendingPathComponent(
    "MacPhotoMasterPad/Sources/Assets.xcassets/AppIcon.appiconset/AppIcon.png"))

print("wrote the icon into \(root.standardizedFileURL.path)")
