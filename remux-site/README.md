# Remux Site

The production website for Remux, served at `getremux.app`.

## Content

One page for people who already use tmux or herdr. It says what Remux is, then only what Remux adds or does
differently on a phone: sessions on several servers, windows, tabs and panes, typing, files, previews, herdr
agents, how it connects, and how to install. Features shared by both backends are written once; the herdr
section covers what only herdr sessions have. Every claim should match the app on `main`.

Writing: plain sentences about what you get, no marketing voice, no repeats of what a heading or screenshot
already shows, and lists where a section holds several separate things.

## Design

- Everything is set in JetBrains Mono, the font Remux's terminals render in.
- Each section is a pane with its heading set into the top border; the pane in view takes the accent.
- Neutral light and dark palettes follow the system, with one accent from the app icon and its amber cursor.
- Keys 1–3 jump between sections; the page works without `script.js`.
- Screens are real app captures in `assets/screens/`, shown without device frames.

## Preview

```bash
python3 -m http.server 4175 --bind 127.0.0.1 --directory remux-site
```

Then open <http://127.0.0.1:4175/>.
