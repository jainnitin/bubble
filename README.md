<p align="center">
  <img src="docs/icon.png" width="128" height="128" alt="Bubble app icon">
</p>

<h1 align="center">Bubble</h1>

<p align="center">A free, native Mac app for <a href="https://github.com/tw93/Mole">Mole</a>, the open-source Mac cleaner.</p>

<p align="center">
  <img src="docs/clean.png" alt="Bubble's Clean screen">
</p>

<p align="center">
  <img src="docs/apps.png" width="49%" alt="Apps">
  <img src="docs/analyze.png" width="49%" alt="Analyze">
</p>

Bubble puts a friendly window on top of Mole's `mo` command-line tool: clean caches, uninstall apps
with their leftovers, run maintenance, map your disk and watch your Mac's vitals. Cleanups run
`mo`, so Mole's safety rules, protected items and history apply exactly as they do in Terminal.

## Install

1. Download `Bubble-X.Y.Z.dmg` from the [latest release](https://github.com/jainnitin/bubble/releases/latest),
   open it and drag **Bubble** to Applications.
2. Open it. If Mole isn't installed yet, Bubble installs it for you.
3. Optionally give Bubble **Full Disk Access**. Bubble works without it: it skips the places macOS
   keeps private, and says so, instead of setting off permission dialogs.

Bubble is signed and notarized by Apple, and updates itself.

## Features

| Section | What it does |
|---|---|
| **Clean** | Scans with `mo clean --dry-run`, lets you review and untick items, then cleans. |
| **Apps** | **Uninstall** apps with their leftovers, natively: everything goes to the Trash, with Undo. **Updates** for Homebrew, App Store and Sparkle apps. **Startup** items you can switch off. |
| **Optimize** | `mo optimize` with live progress. Admin tasks (DNS flush, Spotlight) take one Touch ID prompt, or can be skipped. |
| **Analyze** | A treemap of your disk you can drill into, reveal or move to the Trash. |
| **Status** | Live CPU, memory, disk, network, temperatures and processes, also in the menu bar. |

Also: **Checkup** (click the Bubble logo) checks Mole, permissions and Touch ID for sudo, with a fix
for each problem; **Settings** edits Mole's protected items; **Keep Screen On** and **Clean Screen**
are in the Bubble menu.

## Requirements

- macOS 14 or later.
- Mole 1.59.0 or later. Bubble installs or updates it for you, with Homebrew when it's there,
  otherwise with Mole's official install script (pinned and checksum-verified). No admin password
  needed.

## Privacy

- No analytics, telemetry, crash reporting or account.
- Bubble goes online only to check for its own updates (once a day, can be turned off), when you
  open **Apps ▸ Updates**, and when you install or update Mole or an app.
- Your admin password never passes through Bubble: admin tasks use Touch ID through `sudo`, or
  macOS's own authorization dialog.
- Without Full Disk Access, Clean and Analyze run Mole in a sandbox that skips Desktop, Documents,
  Downloads, Mail, Messages, Photos, iCloud and other apps' containers, so no privacy prompts
  appear. Each screen lists what it skipped.
- On disk, Bubble writes only its preferences and, when you protect items, Mole's
  `~/.config/mole/whitelist` (unticked items are protected there for one run, then restored).

## Known limits

- System-level caches in **Clean** need admin rights, and Mole only uses an already-open sudo
  session for those. Run `sudo -v && mo clean` in Terminal for them.
- Mole rescans when it cleans, so anything new since your preview is cleaned too, as with `mo clean`.

## Developing

See [docs/DEVELOPING.md](docs/DEVELOPING.md) for building, dev builds and releasing.

## Credits and license

Bubble is released under the [MIT License](LICENSE).

- [Mole](https://github.com/tw93/Mole) by tw93 is licensed under GPL-3.0. Bubble runs the `mo`
  you have installed as a separate program and doesn't bundle or link any of its code.
- [Sparkle](https://sparkle-project.org) (MIT) is embedded for self-updates.

Bubble is a separate project from Mole for Mac, the native app by Mole's author.
