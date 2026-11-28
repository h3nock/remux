# Remux App Icon

The production app icon package lives at `../Remux.icon`. It holds one vector
layer, `Assets/panes.svg`, on a flat tile; the system adds the lighting.
`remux-app-icon-master.svg` here is the same drawing flattened onto its tile,
for viewing and for exporting other sizes.

The drawing is one rounded shape cut into four panes by two straight dividers,
with a cursor opening in the round pane, on a 1024 canvas:

- Panes span `188` to `876` across and `164` to `868` down.
- Column divider: `48px`, straight from top to bottom (left column ends at
  `496`, right column starts at `544`).
- Row divider: `48px`, straight from the left edge through the centre (top row
  ends at `528`, bottom row starts at `576`).
- Every corner on a divider is square. Only the outline is rounded. The two
  outer left corners and the lower right corner are continuous corners, drawn
  as one Bézier curve each: radius `96` on the left (the curve covers `124.8px`
  of each edge) and `48` at the lower right (`62.4px` of each edge).
- The round pane's right side is one continuous curve. The diagonal starts at a
  sharp corner, and the corner at its foot is a circular arc of radius `80`.
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
