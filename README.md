# Screen Timer

A menu-bar stay timer for macOS. Shows how long you've been on your
current screen — app + window — ticking live, and resets the moment you
switch. For Chrome apps / PWAs (which have no window title) it reads the
in-app session name via Accessibility, so session switches inside a PWA
reset the timer too.

Click the timer and choose **Open dashboard** for a Stats-style panel:
colored day timeline, per-app stay-length histograms, focus stats.
The menu itself also shows a text summary: stays overall, per app, and within
an app — per tab in Chrome, per session in PWAs, per window elsewhere.
Each app lists its top 6 tabs/sessions; the rest roll up into one line.
Every finished stay is logged to `~/screen-stays.csv`. Everything is
local; nothing is sent anywhere.

Built on [Hammerspoon](https://www.hammerspoon.org) — the installer
sets it up for you.

## Install — pick one

**Double-click:** `Install Screen Timer.command`
(first time: right-click → Open, it's unsigned)

**Terminal one-liner** (after hosting this repo, e.g. on GitHub):
```
curl -fsSL https://raw.githubusercontent.com/anurag1212/scattered-mind/main/install.sh | bash
```

**Manual:** install Hammerspoon, copy `screen-timer.lua` to
`~/.hammerspoon/`, add `require("screen-timer")` to
`~/.hammerspoon/init.lua`, launch Hammerspoon.

## The one manual step

macOS requires *you* to grant Hammerspoon **Accessibility** permission
(System Settings → Privacy & Security → Accessibility). The installer
opens that pane for you. It can't be scripted — that's an Apple rule,
not an installer limitation.

## Uninstall

Double-click `Uninstall Screen Timer.command` — removes the module and
its `require` line, keeps Hammerspoon and your CSV log.

## Configure

Edit the `CONFIG` block at the top of `~/.hammerspoon/screen-timer.lua`:
`granularity` ("app+window+title", "app+window", or "app"),
`minLogSeconds`, `logPath`.
