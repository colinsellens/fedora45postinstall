# Fedora 45 post-install

One script that takes a fresh Fedora 45 Workstation (GNOME) install to a finished desktop: updates, codecs, drivers, snapshots, software, GNOME extensions and settings.

It runs unattended. Every choice is a setting at the top of the script rather than a question, and the menus show what is already installed on the machine.

## Quick start

```bash
git clone https://github.com/colinsellens/fedora45postinstall.git
cd fedora45postinstall
sudo ./fedora45-postinstall.sh
```

| Command | What it does |
|---|---|
| `sudo ./fedora45-postinstall.sh` | Interactive menu |
| `sudo ./fedora45-postinstall.sh A` | Run every step (1–13) |
| `sudo ./fedora45-postinstall.sh 2 4` | Run selected steps |
| `sudo ./fedora45-postinstall.sh S` | Open the software menu |

Run it with `sudo` from your own desktop session, not as root directly: the GNOME step applies extensions and settings to the user who ran `sudo`.

The script also works on its own, without the rest of the repo. In that case the bundled extension and wallpaper are downloaded from this repo on GitHub.

## What it does

| # | Step | Details |
|---|---|---|
| 1 | Update system | `dnf upgrade --refresh`, 10 parallel downloads |
| 2 | RPM Fusion | free, nonfree and free-tainted |
| 3 | Media codecs | full ffmpeg, GStreamer, VA-API hardware decode, DVD, rar/7z |
| 4 | NVIDIA driver | proprietary akmod; choose the current, 580xx or 470xx branch |
| 5 | Other drivers and firmware | Broadcom Wi-Fi, GPU and audio firmware |
| 6 | Build tools | GCC, make, kernel headers |
| 7 | VMware Workstation modules | builds and signs vmmon/vmnet, rebuilds on kernel updates |
| 8 | Btrfs snapshots | snapper, a snapshot before every dnf run, grub-btrfs |
| 9 | Flathub | full catalogue plus Fedora's third-party repos |
| 10 | Firmware updates | fwupd / LVFS |
| 11 | GNOME | extensions, settings, keyboard shortcuts, wallpaper |
| 12 | Microsoft core fonts | Arial, Times New Roman, Verdana and friends |
| 13 | OpenSSL 3 compatibility | for VS Code and other vendor apps |

`A` runs them in a safe order: a snapshot first so there is a rollback point, firmware last. It does not include the software menu; run `S` for that.

With Secure Boot on, one signing key is shared by the NVIDIA, Broadcom and VMware modules, so you enrol a single key once.

## Software

The software menu (`S`) installs each app from dnf first and falls back to Flathub where a Flatpak exists.

| App | Source |
|---|---|
| Brave Origin (stable) | Brave's dnf repo, plus the Bitwarden extension through a managed policy |
| qBittorrent | Fedora, Flathub fallback |
| VLC | Fedora, Flathub fallback |
| Bitwarden | Flathub |
| Mullvad VPN | Mullvad's dnf repo |
| VS Code | Microsoft's dnf repo, Flathub fallback |
| Claude Code | Anthropic's dnf repo (key fingerprint checked), native installer fallback |
| Extension Manager | Flathub |

To add an app, add one line to the `SOFTWARE` table in the script:

```
"key|Menu label|dnf package(s)|Flathub app ID"
```

Leave either the dnf or Flathub field empty to skip it. An app that needs its own repo can define a `sw_pre_<key>` function; `sw_post_<key>`, `sw_fallback_<key>` and `sw_status_<key>` are also picked up by name.

## GNOME extensions

Step 11 installs and enables these. They take effect at your next log-in.

| Extension | Source |
|---|---|
| [Accent Color Everywhere](https://framagit.org/Fred6681/accent-color-everywhere) | Bundled in `extensions/` |
| AppIndicator (tray icons) | Fedora package |
| Dash to Dock | Fedora package |
| [User Themes](https://extensions.gnome.org/extension/19/user-themes/) | extensions.gnome.org |
| [Caffeine](https://extensions.gnome.org/extension/517/caffeine/) | extensions.gnome.org |
| [GSConnect](https://extensions.gnome.org/extension/1319/gsconnect/) | extensions.gnome.org |
| [Clipboard Indicator](https://extensions.gnome.org/extension/779/clipboard-indicator/) | extensions.gnome.org |
| [Desktop Icons NG (DING)](https://extensions.gnome.org/extension/2087/desktop-icons-ng-ding/) | extensions.gnome.org |
| [Transparent Top Bar (Adjustable transparency)](https://extensions.gnome.org/extension/3960/transparent-top-bar-adjustable-transparency/) | extensions.gnome.org |

Extension Manager (Flathub) and GNOME Tweaks are installed alongside them.

To add an extension from extensions.gnome.org, add one line to the `GNOME_EXTENSIONS` table, using the number from its URL:

```
"517|Caffeine"
```

The script downloads the build that matches your GNOME Shell version. If there isn't one, that extension is reported and skipped. Extensions already installed are skipped on later runs.

If the Accent Color Everywhere folder on the machine is a git checkout, the script leaves it untouched, so a working copy is never overwritten.

## Settings

Everything below lives in the `SETTINGS` block at the top of the script.

### GNOME settings applied by step 11

| Area | Setting |
|---|---|
| Appearance | Dark style |
| Appearance | Background set to `wallpapers/forest-fog.jpg` |
| Mouse and touchpad | Pointer speed 75%, tap to click |
| Power | Screen blanks after 15 minutes; no automatic suspend when plugged in |
| Keyboard | Log out is Ctrl+Alt+L |
| Keyboard | Custom shortcut "Resources": Ctrl+Alt+Del runs `gnome-system-monitor` |
| Windows | Minimise and maximise buttons |
| Top bar | Battery percentage, weekday in the clock, hot corner off |
| Display | Night light on |
| Files | Folders sorted before files |

Three tables control these:

- `GNOME_SETTINGS`: one `"schema key value"` line per setting. Settings belonging to an installed extension work too; examples for Accent Color Everywhere are included, commented out.
- `CUSTOM_SHORTCUTS`: one `"name | command | key combination"` line per shortcut. Existing shortcuts are kept.
- `WALLPAPER`: an image in this repo. Set it to empty to leave the background alone.

### Choices

Each is `y` or `n`. Override one for a single run without editing the script:

```bash
sudo OPT_GRUB_BTRFS=n ./fedora45-postinstall.sh 8
```

| Setting | Default | Step | Meaning |
|---|---|---|---|
| `OPT_MESA_TESTING_RETRY` | n | 3 | Retry the Mesa VA-API drivers from updates-testing if they fail |
| `OPT_BROADCOM_WL` | n | 5 | Proprietary Broadcom Wi-Fi driver, if a Broadcom chip is found |
| `OPT_GRUB_BTRFS` | y | 8 | Build grub-btrfs so snapshots can be booted from GRUB |
| `OPT_APPLY_FIRMWARE` | y | 10 | Apply firmware updates (`n` only lists them) |
| `OPT_ACCENT_COLOR` | y | 11 | Accent Color Everywhere extension |
| `OPT_APPINDICATOR` | y | 11 | AppIndicator tray icons |
| `OPT_DASH_TO_DOCK` | y | 11 | Dash to Dock |
| `OPT_MSFONTS_EULA` | y | 12 | You accept the [Microsoft core fonts EULA](https://corefonts.sourceforge.net/eula.htm) |
| `OPT_BRAVE_LOCK_BITWARDEN` | n | S | Force-install Bitwarden in Brave so it can't be switched off |
| `OPT_BRAVE_FLATHUB_FALLBACK` | n | S | Install regular Brave from Flathub if Brave Origin fails |
| `OPT_REBOOT_WHEN_DONE` | y | end | Reboot automatically if a step needs it |
| `VMWARE_BUNDLE` | empty | 7 | Path to the VMware Workstation installer, used if VMware isn't installed |
| `VMWARE_PATCHED_URL` | empty | 7 | Git URL of patched vmmon/vmnet sources, used if the bundled ones don't build |

## What still asks for input

- **NVIDIA driver:** a yes/no and the driver branch, and only when an NVIDIA card is detected. With no card the step is skipped.
- **Secure Boot:** if it is on, enrolling the signing key asks you to choose a one-time password. You type it once at the blue MOK screen on the next reboot. That screen times out, so be at the machine for that reboot or set `OPT_REBOOT_WHEN_DONE=n`.
- **VMware:** its own installer shows a licence if `VMWARE_BUNDLE` is set.

## Good to know

- **Status:** the menus show what is already installed, read from the system, so they are accurate after a reboot. Steps 1 and 10 stay blank because checking them needs the network.
- **Re-running is safe:** steps skip or refresh what is already there.
- **Log:** everything is written to `/var/log/fedora45-postinstall.log`.
- **Other Fedora versions:** the script warns but carries on; most steps should still work.

## Licence

The script is free software, licensed under the [GNU General Public License v3.0 or later](LICENSE) (GPL-3.0-or-later).

The wallpaper is not covered by the GPL. `wallpapers/forest-fog.jpg` is ["aerial view of pine trees in mist"](https://unsplash.com/photos/aerial-view-of-pine-trees-in-mist-OYFHT4X5isg) by Dan Otis, used under the [Unsplash License](https://unsplash.com/license).

In short, for the script: you may use, study, change and share it. If you pass it on, changed or not, you must pass it on under the same licence, keep the copyright and licence notices, and make the source available. It comes with no warranty.

## Credits

- **colinsellens:** author and maintainer.
- **Claude** (Anthropic's AI model): wrote much of the script and this README, working with the author.
- **Fred6681:** [Accent Color Everywhere](https://framagit.org/Fred6681/accent-color-everywhere), bundled in `extensions/` under its own GPL-3.0-or-later licence.
- **Dan Otis** ([@danotis](https://unsplash.com/@danotis) on Unsplash): the wallpaper photo.
- The authors of the other extensions and apps this script installs.
