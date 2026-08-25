# IconGen

Draws the app icon rather than storing it as a PNG nobody can adjust, so the
shape, the palette and the sizes stay one set of numbers.

    swift run --package-path Tools/IconGen IconGen .

That writes three files, because three things ask for the icon in three shapes:
`icons/AppIcon-1024.png` (what `scripts/build-app-bundle.sh` sips into the
`.icns`), `Sources/MacPhotoMaster/Resources/AppIcon.png` (the Dock icon a plain
`swift run` gets, which has no bundle and so no `CFBundleIconFile`), and the
iPad asset catalogue's `AppIcon.png`. The first two carry their own squircle,
padding and shadow; the iPad one is full bleed, because iOS applies the mask
and the shadow itself.

## Why it is a package of its own

The tile - the teal, the continuous-corner squircle, the light from above, the
shadow, the 824/1024 grid every Dock icon sits on - comes from
[IconForge](https://github.com/BrianSmithPhotos/IconForge), which SwiftProj
draws its icon with too. Only `Aperture.swift` belongs to this app. That split
is what makes the two read as a family without a copied file drifting between
them.

It is a separate `Package.swift` rather than a target in the app's, because it
is a generator run by hand when the icon changes, not something the app links
against - so it stays off the app's dependency graph.

The eight camera variants this design was chosen from (lens, body, album
corners, film, viewfinder) are in the history at `03659bd` if the mark is ever
worth revisiting.
