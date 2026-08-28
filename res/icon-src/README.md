# Icon source

The IHPortals mark has no vector master -- it was originally delivered as PNGs.
`render.js` is the source instead: the drawing is defined parametrically as
signed-distance shapes, so it can be regenerated at any size without a design
tool, and without ImageMagick or Python (neither is available on the build box).

    node res/icon-src/generate.js

Rewrites every Android density, the adaptive-icon foreground, the notification
glyph, and the Windows `.ico` files. Colour is `MyTheme.accent` (#E9A13B),
matching the app exactly; edit `ART`/`EARS`/`STROKE` in `render.js` to change
the drawing.
