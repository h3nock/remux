# HerdrWire golden fixtures

Byte streams recorded from the official Herdr v0.9.3 macOS arm64 binary (tag `v0.9.3`, commit
`7b116c05`), each through `herdr --session NAME remote-client-bridge` on an isolated server with its
own `HOME` and XDG directories. One file pair per recorded client:

- `herdr-<scenario>-<client>.s2c.bin`: every byte the server sent, framed as on the wire.
- `herdr-<scenario>-<client>.c2s.bin`: every byte the client sent (omitted for the 1 MiB paste).
- `herdr-<scenario>-<client>.expected.json`: each server message's offset, payload length, tag and
  decoded fields in Herdr's serde JSON layout (`delta`, `scroll` and `reuse` add the decoded surface
  encodings), and each client message with its exact bytes. Decoded by an independent reference
  decoder whose rebuilt screens matched Herdr's own `pane.read`.

`herdr-graphics-placements-A` holds two single messages from a recording of a PNG shown with the kitty
graphics protocol: a delta and a full surface that place the picture without carrying its bytes (the
picture itself is 3 MB). Its asset fingerprint is above 2^63.

Scenarios: handshakes with and without the compression flags and the four rejections, patch and
delta, reuse, scroll, surface activation, an inactive connection, resizes, the command lane, health
pings, notifications, bell and clipboard, semantic input, cell styles and wide characters, the paste
limit, and agent view.
