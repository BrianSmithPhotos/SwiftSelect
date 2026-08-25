# IconGen

Draws the app icon rather than storing it as a PNG nobody can adjust, so the
shape, the palette and the sizes stay one set of numbers.

    swift Tools/IconGen/IconGen.swift app .          # write the icon into the repo
    swift Tools/IconGen/IconGen.swift sheet <dir>    # every variant, big and small
    swift Tools/IconGen/IconGen.swift compare <dir>  # the iris seam options

`app` writes three files, because three things ask for the icon in three shapes:
`icons/AppIcon-1024.png` (what `scripts/build-app-bundle.sh` sips into the
`.icns`), `Sources/MacPhotoMaster/Resources/AppIcon.png` (the Dock icon a plain
`swift run` gets, which has no bundle and so no `CFBundleIconFile`), and the
iPad asset catalogue's `AppIcon.png`. The first two carry their own squircle,
padding and shadow; the iPad one is full bleed, because iOS applies the mask
and the shadow itself.

The teal, the squircle and the lighting are shared with the SwiftProj icon on
purpose - only `drawArt` differs, which is what makes the two read as a family.
That shared part is on its way out into its own package.
