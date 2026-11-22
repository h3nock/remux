# Remux site

The website for Remux, served at `getremux.app`. Plain HTML, CSS and JavaScript, with no build step.

## Files

- `index.html`: the page.
- `styles.css`: every style, in page order: fonts, colour tokens, base, top line, panes, opening, buttons, screens,
  features, install, footer, viewer, scan panel.
- `script.js`: section keys, the opening recording, the full-size viewer and the scan panel.
- `fonts/`: JetBrains Mono and Inter, Latin and Latin Extended, with their OFL licences. They are served from the site,
  so a visit contacts no one else.
- `shots/`: the screens, each at 600, 900 and 1206 pixels wide, and the opening recording as AV1 and H.264 with its
  poster.
- `assets/remux-app-icon.svg`, `apple-touch-icon.png`, `og.png`: icons and the link preview image.

## Design

- Sections are panes with their name set into the top border, the way a multiplexer titles a pane.
- JetBrains Mono sets the frame, names, labels and keys; Inter sets running text. Inter shares JetBrains Mono's letter
  height, so terminal words sit level inside a sentence.
- Bright is what you scan (names, buttons, keys, links); dim is what you read.
- Neutrals are GitHub's Light and Dark Default terminal themes. Teal marks what you act on; amber is the cursor after
  the name.
- Vertical spacing is whole or half lines (`--lh`); horizontal spacing is whole characters.
- Layout changes at window widths 520, 559, 760 and 900, and at pane widths 700 and 820.

## Behaviour

- The section keys scroll to a section and mark it current; pressing a key's digit does the same.
- The opening recording plays while it is on screen, never on its own with Reduce Motion, and can be paused. A click on
  the phone, or its enlarge button, opens it full size from the same moment.
- A screen opens full size at the largest width its image offers.
- On a computer, "Join the TestFlight beta" opens a panel with a QR code to scan with an iPhone, since Apple's page only
  says to open the link on an iPhone. Touch screens follow the link.

## Changing it

- When `styles.css` or `script.js` changes, raise its `?v=` number in `index.html`, so returning visitors get the new
  file.
- The QR code is inline SVG made with [segno](https://pypi.org/project/segno/). If the TestFlight link changes,
  regenerate it and replace the `<svg class="qr" …>` in `index.html`:

  ```bash
  python3 -c "import segno; print(segno.make('https://testflight.apple.com/join/fHqG1ruE', error='m', micro=False)\
    .svg_inline(scale=6, border=2, dark='#000', light=None).replace('#000', 'currentColor'))"
  ```

  Keep the `class="qr"`, `role="img"` and `aria-label` attributes on the new `<svg>`.
- A new screen needs all three widths (`name.webp` at 600, `name-900.webp`, `name-1206.webp`) and a `srcset` listing
  them; the viewer opens the last one.

## Preview

```bash
python3 -m http.server 4175 --bind 127.0.0.1 --directory remux-site
```

Then open <http://127.0.0.1:4175/>.
