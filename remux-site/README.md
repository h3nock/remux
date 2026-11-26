# Remux site

The website for Remux, served at `getremux.app`. Plain HTML, CSS and JavaScript, with no build step.

## Files

- `index.html`: the page.
- `styles.css`: every style, in page order: fonts, colour tokens, base, top line, buttons and keys, opening, features,
  install, footer, viewer, scan panel.
- `script.js`: section keys, the opening recording, the full-size viewer and the scan panel.
- `assets/fonts/`: JetBrains Mono and Inter, Latin and Latin Extended, and JetBrains Mono's variable file for the
  light headline weight, with their OFL licences. They are served from the site, so a visit contacts no one else.
- `assets/shots/`: the screens, each at 600, 900 and 1206 pixels wide, and the opening recording as AV1 and H.264
  with its poster.
- `assets/frame/`: the iPhone frame around the opening recording, and the mask that cuts the screen to its corners.
- `assets/favicon.svg`, `assets/favicon-32.png`: the browser tab icon, a simpler drawing of the app icon made for
  16 pixels.
- `assets/remux-app-icon-76.png`, `-152.png`, `-228.png`: the app icon as iOS draws it, rendered at each size.
- `apple-touch-icon.png`, `og.png`: the Home Screen icon and the link preview image. They stay at the site's root
  because other sites keep their addresses.
- `favicon.ico`: the tab icon at 16, 32 and 48 pixels, for anything that asks for `/favicon.ico` without reading
  the page, such as a tab that shows one of the site's images on its own.

## Design

- One column of content, 1010 pixels at its widest. Features sit on two columns from 761 pixels up and on one below.
- JetBrains Mono sets the headline, names, labels, buttons and keys; Inter sets running text. The headline and
  "Get Remux." use the light weight of JetBrains Mono's variable file.
- Each feature shows a part of a real screen at phone width. A click or tap opens the whole screen.
- Neutrals are near-black and near-white with a slight cool tint. The one colour is the app icon's green: it fills the
  main button and marks the cursor after the name, the current section and the session name in the footer.
- Both themes follow the system setting.
- Layout changes at window widths 374, 520, 559, 760, 860, 900 and 1000, and for windows shorter than 480.

## Behaviour

- The section keys scroll to a section and mark it current; pressing a key's digit does the same.
- The opening recording plays while it is on screen, never on its own with Reduce Motion, and can be paused. A click
  on the phone plays or pauses it in place; its enlarge button opens it full size from the same moment.
- A screen opens full size at the largest width its image offers.
- On a computer, the install section shows a QR code to scan with an iPhone, and "Join the TestFlight beta" opens a
  panel with the same code, since Apple's page only says to open the link on an iPhone. Touch screens follow the link.

## Changing it

- When `styles.css` or `script.js` changes, raise its `?v=` number in `index.html`, so returning visitors get the new
  file.
- The QR code is inline SVG made with [segno](https://pypi.org/project/segno/), and it appears twice in `index.html`:
  in the install section and in the scan panel. If the TestFlight link changes, regenerate it and replace the `<path>`
  inside both `<svg class="qr" …>` elements:

  ```bash
  python3 -c "import segno; print(segno.make('https://testflight.apple.com/join/fHqG1ruE', error='m', micro=False)\
    .svg_inline(scale=6, border=2, dark='#000', light=None).replace('#000', 'currentColor'))"
  ```

  Keep each `<svg>`'s own `class`, `role`, `aria-label` and size attributes.
- A new screen needs all three widths (`name.webp` at 600, `name-900.webp`, `name-1206.webp`) and a `srcset` listing
  them; the viewer opens the last one.

## Preview

```bash
python3 -m http.server 4175 --bind 127.0.0.1 --directory remux-site
```

Then open <http://127.0.0.1:4175/>.
