# Testing

Remux has three kinds of tests. Set up the project first, as described in
[development.md](development.md).

| Kind | Target | Scheme | Needs |
| --- | --- | --- | --- |
| Unit tests | `RemuxTests` | `Remux` | A simulator |
| Simulated UI tests | `RemuxUITests` | `RemuxUIOnly` | A simulator |
| Live UI tests | `RemuxUITests` | `RemuxUIOnly`, through `scripts/remux_live_ui_test_with_cleanup.sh` | A simulator and an SSH server with tmux |

The commands below use a simulator named `iPhone 17`. Replace the name with
any iPhone simulator from `xcrun simctl list devices available`.

## Unit Tests

```bash
xcodebuild test \
  -project Remux.xcodeproj \
  -scheme Remux \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest'
```

To run one test class or method, add `-only-testing`:

```bash
xcodebuild test \
  -project Remux.xcodeproj \
  -scheme Remux \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:RemuxTests/RemuxSmokeTests
```

`scripts/test_install_authorized_key.sh` tests the shell script the app uses
to install a public key on a server. It runs without Xcode.

## Simulated UI Tests

Most UI tests launch the app with `REMUX_UI_TESTING=1`. The app then keeps its
data in memory and runs tmux over a scripted in-app connection instead of SSH.
Adding a server and listing a server's tmux sessions still open real SSH
connections in this mode. The other UI tests are the live tests: the
`testLive*` tests and `testCaptureDesignReviewScreens`.

Run one:

```bash
xcodebuild test \
  -project Remux.xcodeproj \
  -scheme RemuxUIOnly \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:RemuxUITests/RemuxAppUITests/testSettingsExposeFontAndThemeControls
```

Run them all:

```bash
xcodebuild test \
  -project Remux.xcodeproj \
  -scheme RemuxUIOnly \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest'
```

This also runs the live tests in the scheme. Without
`/tmp/remux-live-ssh.json` they skip. With it, they fail, because live tests
only run through the live test script.

## Live UI Tests

Live tests run the app in the simulator against a real SSH server and tmux,
and check terminal behavior end to end.
`testCaptureDesignReviewScreens` also needs the live setup; it saves
screenshots of the main screens in the result bundle.
`scripts/remux_live_ui_test_with_cleanup.sh` builds the UI tests, runs the
tests you select in one `xcodebuild` run, gives each test its own tmux session,
and removes those sessions as each test finishes.

### Server Requirements

- An SSH server that accepts a password or an OpenSSH private key (Ed25519,
  RSA, or ECDSA) for the test account.
- tmux 3.1 or later.
- A login shell that runs POSIX shell syntax, such as zsh or bash. The tests
  type commands like `while [ $i -lt 80 ]; do ...; done`.
- `zsh`, `python3`, `vim`, and `less`. The file preview test also starts a
  web server on `127.0.0.1:18923` on the server, so that port must be free.

Use a dedicated test account, or at least a key you made only for these tests.
The test run copies the credential into the app's launch environment, and it
ends up in the run's result bundle (see [Logs and Results](#logs-and-results)).

### Isolated tmux Server

Run the tests on their own tmux server, not on the one that holds your real
sessions. The tests create and kill sessions and windows, and some of them
assume tmux's default settings, such as the `C-b` prefix. On the server,
create a wrapper that starts tmux on its own socket without your config.
Use the absolute path of tmux on the server (`command -v tmux`):

```bash
mkdir -p ~/bin
cat > ~/bin/remux-test-tmux <<'EOF'
#!/bin/sh
exec /opt/homebrew/bin/tmux -L remux-test -f /dev/null "$@"
EOF
chmod +x ~/bin/remux-test-tmux
```

Set `tmuxExecutablePath` in the config to the wrapper's absolute path. The app
and the script both use it. When you're done, stop that server:

```bash
~/bin/remux-test-tmux kill-server
```

### Host Key

The script trusts the server only if its host key is in your
`~/.ssh/known_hosts`. Without an entry, it stops right away with status 1 and
prints nothing. Connect once with `ssh` and accept the key, then check that
this prints an entry:

```bash
ssh-keygen -F <host>
```

For a port other than 22, look up `'[<host>]:<port>'` instead.

### Config File

The script and the tests read `/tmp/remux-live-ssh.json`. Every value is a
JSON string.

| Field | Required | Meaning |
| --- | --- | --- |
| `host` | Yes | Server hostname or IP address. |
| `username` | Yes | SSH user. |
| `port` | No | SSH port, as a string such as `"22"`. Defaults to `"22"`. |
| `privateKeyPEM` | One of these two | The OpenSSH private key text. Used when both are set. |
| `password` | One of these two | The SSH password. |
| `privateKeyPassphrase` | No | Passphrase for an encrypted key. |
| `tmuxExecutablePath` | No | Absolute path of tmux, or of the wrapper above, on the server. Only letters, digits, `.`, `_`, `-` and `/`. |
| `displayName` | No | Server name shown in the app. Defaults to `Live SSH`. |
| `sessionName` | No | tmux session for `testCaptureDesignReviewScreens`. Defaults to `remux-live-e2e`. |

Create it readable only by you, for example with a key:

```bash
(umask 077 && ruby -rjson -e 'puts JSON.pretty_generate(
  "host" => "server.example.com",
  "port" => "22",
  "username" => "remux-test",
  "privateKeyPEM" => File.read(File.expand_path("~/.ssh/remux_test_ed25519")),
  "tmuxExecutablePath" => "/home/remux-test/bin/remux-test-tmux"
)' > /tmp/remux-live-ssh.json)
```

Delete it when you're done testing:

```bash
rm /tmp/remux-live-ssh.json
```

### Running

The script needs `ruby`, `ssh`, `ssh-keygen`, and `xcodebuild`. macOS includes
the first three.

Run one test:

```bash
scripts/remux_live_ui_test_with_cleanup.sh \
  --destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  --only-testing RemuxUITests/RemuxAppUITests/testLiveSSHSeededServerOpensReadyTerminalWhenConfigured
```

Run the whole live suite:

```bash
tests=()
for test in $(grep -o 'func testLive[A-Za-z]*' RemuxAppUITests/RemuxAppUITests.swift | cut -d' ' -f2); do
  [ "$test" = testLiveAgentTUIPaneSwitchProfileWhenConfigured ] && continue
  tests+=(--only-testing "RemuxUITests/RemuxAppUITests/$test")
done
scripts/remux_live_ui_test_with_cleanup.sh \
  --destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  "${tests[@]}"
```

The loop leaves out `testLiveAgentTUIPaneSwitchProfileWhenConfigured`, which
needs `REMUX_LIVE_AGENT_TUI_SESSION` set to an existing two-pane tmux session
running real agent TUIs.

One test takes a few minutes, most of it building. The whole suite of 26 tests
took about 23 minutes after the build on an iPhone 17 simulator.

Other options:

- `--destination` defaults to `platform=iOS Simulator,name=iPhone 17,OS=latest`.
- `--configuration Release` builds Release with the debug hooks the tests
  need. The default is `Debug`.
- `--development-team <team-id>` signs the build for a device destination.
- `--derived-data-path <path>` passes `-derivedDataPath` to `xcodebuild`.

The script prints each test's result and ends with:

```text
live UI test status: xcodebuild <status>, tmux expectations and cleanup <status>
```

It exits non-zero when a test fails, or when a tmux check or a session
cleanup fails. After a test finishes, the script checks the tmux state the
test recorded, such as pane contents and window counts, and then kills that
test's `remux-latency-*` sessions. A few tests leave small files in the
server's `/tmp`, such as `/tmp/remux-scroll.txt`.

### Logs and Results

Each run writes to `.local/logs/` in your checkout:

- `live-ui-cleanup-<stamp>-build.log`: the build output.
- `live-ui-cleanup-<stamp>.log`: the test output.
- `live-ui-cleanup-<stamp>.xcresult`: the result bundle, with screenshots.

The result bundle contains the private key or password from your config. Read
what you need, then delete it, and never attach it to an issue or pull
request:

```bash
rm -rf .local/logs/live-ui-cleanup-*
```

### Why Live Tests Aren't in CI

They need a reachable SSH server with tmux and a credential for it, and the
whole suite takes over 20 minutes.

## What CI Runs

The CI workflow, [.github/workflows/ci.yml](../.github/workflows/ci.yml), runs
on pushes to `main` and on pull requests. Its App job uses Xcode 26.4.1 on a
macOS 26 runner and:

1. Runs `scripts/test_install_authorized_key.sh`.
2. Fetches GhosttyKit and checks that it is a ReleaseFast build.
3. Runs `xcodegen generate` and fails if the checked-in project changes.
4. Runs the unit tests (`-only-testing:RemuxTests`) on an iPhone 17e
   simulator with the newest iOS runtime on the runner.

CI doesn't build or run the UI tests. Pull requests that only change `docs/`,
`README.md`, `LICENSE`, or `remux-site/` skip the App job. A separate Site job
checks `remux-site/`.

## Troubleshooting

| Message | Fix |
| --- | --- |
| `Unable to find a device matching the provided destination specifier` | No simulator has that name. Pick one from `xcrun simctl list devices available`. |
| `Missing /tmp/remux-live-ssh.json; cannot run live SSH UI tests.` | Create the [config file](#config-file). |
| `Refusing live SSH host trust because Remux did not display the expected fingerprint.` | The script expects the host key in the first `ssh-keygen -F <host>` entry, and Remux received a different one. Remux asks for the server's Ed25519 host key first, so make that the first entry. |
| `tmuxExecutablePath in /tmp/remux-live-ssh.json must be an absolute path of [A-Za-z0-9._/-] characters.` | Use an absolute path with only those characters. |
| `/tmp/remux-live-ssh.json must include password or privateKeyPEM.` | Add one of them. |
| The live script exits at once with status 1 and prints nothing. | `~/.ssh/known_hosts` has no entry for the host and port ([Host Key](#host-key)), or a config value isn't a string, often `port`: write `"22"`, not `22`. |
| `Create /tmp/remux-live-ssh.json inside the simulator to run live SSH UI testing.` | A live test was skipped because there is no config file. |
| `Live SSH UI tests that create remux-latency-* tmux sessions must run through scripts/remux_live_ui_test_with_cleanup.sh; ...` | Run live tests through the script, not directly with `xcodebuild`. |
