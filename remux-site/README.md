# Remux Site

The website for Remux, served at `getremux.app` from this folder.

It is one page in a terminal style: the opening loop, then one section per feature with two screenshots of the app.
`404.html` is the not-found page, `og.png` the image link previews show, and `apple-touch-icon.png` the icon iOS uses
for the home screen and bookmarks.

## Files

- `shots/opening-av1.mp4` is the opening loop, with `opening.mp4` (H.264) for browsers without AV1 and
  `opening-poster.webp` as its first frame.
- `shots/` also holds each section's screenshots, at 600, 900 and 1206 pixels wide.
- `assets/remux-app-icon.svg` is the app icon, used as the favicon.

## Preview

```bash
python3 -m http.server 4175 --bind 127.0.0.1 --directory remux-site
```

Then open <http://127.0.0.1:4175/>. Safari plays the loop only from a server that answers byte-range requests, which
Python's `http.server` doesn't, so check the video in another browser or on the deployed site.
