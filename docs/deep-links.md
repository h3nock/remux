# Links

Remux opens `remux://` links to a tmux session on a saved server, and
optionally to a window and pane in it:

```text
remux://open?server=<server>&session=<session>[&window=<window>][&pane=<pane>]
```

| Parameter | Meaning |
| --- | --- |
| `server` | A saved server's display name, `user@host`, `user@host:port`, host, or id. Matching ignores case. |
| `session` | The tmux session name. tmux creates the session if it does not exist, as when you start one from the app. |
| `window` | Optional. A tmux window target: an index (`2`), a name (`logs`), or an id (`@4`). Indexes are tmux's own, the numbers in the status bar, so they start at your `base-index` (0 by default). |
| `pane` | Optional. A tmux pane target: an index in the window (`1`, counted from `pane-base-index`) or an id (`%7`, written `%257` in the link because `%` must be percent-encoded). An id overrides `window`. |

Percent-encode values that contain spaces or reserved characters, for example
`server=Build%20Host`.

Remux tries the server rules in the order above and uses the first one that
matches exactly one saved server. If two servers match, the link fails, so
name the server by its display name or id instead.

If the session is already open in Remux, the link switches to it. tmux
resolves `window` and `pane` after the session attaches, so they mean the
same as `tmux select-window -t` and `tmux select-pane -t`. If tmux cannot
find them, the session still opens and Remux shows the tmux error.

Long-press any session in the library or the session list and choose
**Copy Link** to copy a link to it.

## Examples

```text
remux://open?server=devbox&session=main
remux://open?server=will@devbox.example.com&session=agents&window=2
remux://open?server=devbox&session=main&window=logs&pane=1
```
