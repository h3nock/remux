# Remux App Icon

The production app icon package lives at `../Remux.icon`. It holds one vector
layer, `Assets/panes.svg`, on a flat tile; the system adds the lighting.
`remux-app-icon-master.svg` here is the same drawing flattened onto its tile,
for viewing and for exporting other sizes.

The drawing is four panes with a cursor opening in the round one, on a 1024
canvas:

- Panes span `188` to `876` across and `164` to `868` down.
- Column gutter: `48px` (left column ends at `496`, right column starts at `544`).
- Row gutter: `48px` (top row ends at `528`, bottom row starts at `576`).
- Corner radius: `96` on the outer left corners, `48` elsewhere.
- Cursor opening: `56` by `124`, showing the tile through the pane.

Colours:

- Tile: `#17402F`.
- Panes: `#F3ECD8`.
- The icon is the same in light and Dark mode. `icon.json` states the Dark
  colours explicitly: left out, the system substitutes its own dark tile and
  recolours the panes.
- In the tinted appearances the panes use a neutral light grey and the system
  supplies the colour.

Keep every edge on a whole pixel, and keep the layer a flat shape with no
baked gradient, shadow or highlight.
