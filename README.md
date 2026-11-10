# HostPulse

A native macOS menu bar app and desktop widget that shows live vitals of
machines you can reach over SSH: CPU (total and per core), memory, temperatures,
fans, power, Wi-Fi signal, network, disk and the top 3 processes.

Builds with the Xcode Command Line Tools; full Xcode isn't needed.

## Install

On any Mac running macOS 14 (Sonoma) or newer, Apple Silicon or Intel:

```sh
curl -fsSL https://raw.githubusercontent.com/kkyusuftk/hostpulse/main/install.sh | bash
```

This downloads the latest [release](https://github.com/kkyusuftk/hostpulse/releases),
installs it to `/Applications` (or `~/Applications` if you can't write there),
registers the widget and launches the app. Run the same command again to update.

HostPulse isn't notarized by Apple, so the script clears macOS's quarantine flag
for you. If you download `HostPulse.zip` from the releases page by hand instead,
run `xattr -dr com.apple.quarantine /Applications/HostPulse.app` once, or allow
it under System Settings → Privacy & Security.

### Build from source

Needs only the Xcode Command Line Tools (`xcode-select --install`):

```sh
./build.sh install
```

This builds `HostPulse.app`, installs it to `/Applications` (or `~/Applications`
if you can't write there), registers the widget and launches the app. HostPulse
lives in the menu bar and turns on "Open at login" the first time it runs.

Add the widget: right-click the desktop → **Edit Widgets…** → search
**HostPulse**. There are two:

- **Host Vitals** (small, medium, large): the primary host.
- **All Hosts** (medium, large): one row per machine.

Clicking a widget opens the dashboard window.

## Hosts

Open the menu bar popover → gear icon → **Hosts** → **+**. You can pick any alias
from `~/.ssh/config` or type `user@host`. HostPulse runs `/usr/bin/ssh` in batch
mode with your own config, keys and agent. A host works if this works in
Terminal without a password prompt:

```sh
ssh <host> true
```

If it doesn't, run `ssh-copy-id <host>` once. New host keys are accepted the
first time (`StrictHostKeyChecking=accept-new`); changed keys are refused.

The star marks the **primary host**. It appears in the menu bar (CPU % and CPU
temperature) and in the Host Vitals widget.

## What runs on the remote machine

Each poll pipes `Sources/Remote/collect.sh` to `sh -s` on the host. It's a
read-only POSIX shell + awk script that works on **macOS and Linux**, and it
reuses one multiplexed SSH connection (`ControlMaster`). A poll of a Mac mini
takes about 1.5 s.

On **Macs**, HostPulse also copies a small helper (`hostpulse-probe`, ~150 KB,
arm64 + x86_64) to `~/.cache/hostpulse/` on the remote. It reads the SMC and the
HID temperature sensors, fans, system power, per-core load and Wi-Fi (CoreWLAN).
It needs no root and changes nothing. Without it, macOS gives no temperatures to
a non-root SSH session. You can turn it off per host; to remove it, run
`rm -rf ~/.cache/hostpulse` on the remote.

On **Linux**, temperatures come from `/sys/class/hwmon` and thermal zones, Wi-Fi
from `/proc/net/wireless` (+ `iw` for the SSID), and processes and CPU from
`/proc`. No helper is needed. This path was tested on Debian and Alpine
(BusyBox) containers.

## Widget refresh rate

macOS decides how often widgets redraw. When HostPulse isn't the frontmost app,
Apple budgets roughly 40–70 widget reloads a day, so the widget may lag a few
minutes behind. The header always says when the reading was taken. Anything
that needs to be live updates on every poll (default 10 s):

- the **menu bar** item and popover. The popover is a compact list: one row per
  machine with its name, hardware (model, chip, cores) and RAM use. Click a row
  for the full card in the dashboard.
- the **dashboard** window
- the **Live desktop widget**: a desktop-level panel with one large card per
  machine, up to three per row; it grows as you add hosts. Turn it on from the
  popover or Settings → General. Drag it anywhere; right-click for
  options.

Settings → General → "Last widget refresh" shows when macOS last redrew the
widget.

## Files

| Path | What |
| --- | --- |
| `~/Library/Application Support/HostPulse/settings.json` | hosts and options |
| `~/Library/Application Support/HostPulse/snapshots.json` | latest readings (the widget reads this) |
| `/tmp/hostpulse-<uid>/` | SSH connection sockets |
| `~/.cache/hostpulse/probe-*` (remote Macs) | sensor helper |

The widget is signed ad-hoc and has no App Group, so its sandbox gets
access to exactly one folder through a home-relative exception
(`Resources/Widget.entitlements`).

**Uninstall:** quit HostPulse, delete the app, and delete
`~/Library/Application Support/HostPulse`.

## Releasing

Push a version tag and GitHub Actions builds a universal app and publishes it as
a release, which the install script picks up:

```sh
git tag v1.1.0 && git push origin v1.1.0
```

`./build.sh package` makes the same `build/HostPulse.zip` locally.

## Layout

```
build.sh                     build, install or package (swiftc, clang, codesign)
install.sh                   one-line installer that downloads the latest release
.github/workflows/           CI build + GitHub release on version tags
Sources/App/                 menu bar app: SSH polling, parser, popover, settings
Sources/Widget/              WidgetKit extension (read-only)
Sources/Shared/              models, storage and the SwiftUI cards used everywhere
Sources/Remote/collect.sh    collector that runs on the remote machine
Sources/Probe/               sensor helper for remote Macs (Objective-C)
Resources/                   Info.plists, entitlements, icon
Tools/                       icon generator, widget preview renderer
```

Render the widget layouts to PNGs without WidgetKit (handy while tweaking the
design):

```sh
swiftc -parse-as-library Sources/Shared/*.swift Sources/App/Parser.swift Tools/render-previews.swift -o build/render
ssh mini 'sh -s -- - 1' < Sources/Remote/collect.sh > build/sample.txt
build/render build/sample.txt build/previews
```
