#!/usr/bin/env bash
# =============================================================================
#  fedora45-postinstall.sh
#  Post-install setup for Fedora 45 Workstation (GNOME)
#
#  Copyright (C) 2026 colinsellens
#  SPDX-License-Identifier: GPL-3.0-or-later
#  This program is free software: you can redistribute it and/or modify it under
#  the terms of the GNU General Public License as published by the Free Software
#  Foundation, either version 3 of the License, or (at your option) any later
#  version. It comes with ABSOLUTELY NO WARRANTY. See the LICENSE file.
#
#   1) Full system update
#   2) RPM Fusion (free + nonfree, + free-tainted for DVD)
#   3) Media codecs (full ffmpeg, GStreamer, VA-API, DVD, archive formats)
#   4) NVIDIA proprietary driver (choose current / 580xx / 470xx branch)
#   5) Other drivers & firmware (Broadcom Wi-Fi, GPU/audio firmware)
#   6) Build tools (GCC, make, kernel-devel/headers)
#   7) VMware Workstation Pro modules (vmmon/vmnet): build, sign, auto-rebuild
#   Extras:
#   8) Btrfs snapshots: snapper, snapshot before every dnf run, optional grub-btrfs
#   9) Flathub (full) + Fedora third-party repos
#  10) Firmware updates via fwupd
#  11) GNOME tweaks: min/max buttons, AppIndicator, Dash to Dock, Extension Manager,
#      Accent Color Everywhere (bundled in extensions/ in this repo), plus the
#      extensions.gnome.org extensions listed in GNOME_EXTENSIONS, the desktop
#      background, custom keyboard shortcuts and the GNOME_SETTINGS table
#  12) Microsoft core fonts (extracted from the original corefonts packages)
#  13) OpenSSL 3 compatibility libraries
#  14) Gaming: Steam (RPM Fusion), Proton-GE, ProtonUp-Qt, Lutris, NTSYNC,
#      GameMode, MangoHud, gamescope
#   A) All of the above - snapshot first, firmware last
#   S) Software submenu: Brave Origin, qBittorrent, VLC, Bitwarden, Mullvad VPN,
#      VS Code, Claude Code, Extension Manager  (dnf first, Flathub fallback)
#
#  Unattended: the steps don't stop to ask questions. Every choice is a setting
#  in the SETTINGS block below - edit it, or override one for a single run:
#      sudo OPT_GRUB_BTRFS=y ./fedora45-postinstall.sh 8
#  Two exceptions: the NVIDIA driver is confirmed first (and only when an NVIDIA
#  card is detected), and with Secure Boot on, mokutil asks you to choose a
#  one-time key-enrolment password.
#  The menus show what is already installed, detected from the system.
#
#  Secure Boot: one signing key (the akmods MOK key) is shared by the NVIDIA
#  akmod, the Broadcom akmod and the VMware modules, so you enrol ONE key once.
#
#  Usage:  sudo ./fedora45-postinstall.sh        (interactive menu)
#          sudo ./fedora45-postinstall.sh A      (run everything)
#          sudo ./fedora45-postinstall.sh 2 4    (run selected steps)
#          sudo ./fedora45-postinstall.sh S      (go straight to the software menu)
# =============================================================================

set -uo pipefail

LOG="/var/log/fedora45-postinstall.log"
AKMODS_KEY="/etc/pki/akmods/private/private_key.priv"
AKMODS_CERT="/etc/pki/akmods/certs/public_key.der"
VMW_HELPER="/usr/local/sbin/vmware-modules-build"
VMW_HOOK="/etc/kernel/install.d/99-vmware-modules.install"
VMW_SERVICE="/etc/systemd/system/vmware-modules-check.service"
VMW_PATCHED_SRC="/usr/local/src/vmware-host-modules"

# GNOME extensions shipped in this repo under extensions/<uuid>/. If the script
# is run on its own (without the rest of the repo), they're fetched from GitHub.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
REPO_TARBALL="https://github.com/colinsellens/fedora45postinstall/archive/refs/heads/main.tar.gz"
REPO_RAW="https://raw.githubusercontent.com/colinsellens/fedora45postinstall/main"
ACCENT_UUID="accent-color-everywhere@framagit.org"

# =============================================================================
#  SETTINGS  - y/n answers to everything the script used to ask.
#  Edit here, or override per run:  sudo OPT_DASH_TO_DOCK=y ./fedora45-postinstall.sh 11
# =============================================================================
OPT_MESA_TESTING_RETRY="${OPT_MESA_TESTING_RETRY:-n}"   #  3: retry mesa-va-drivers-freeworld from updates-testing if it fails
OPT_BROADCOM_WL="${OPT_BROADCOM_WL:-n}"                 #  5: proprietary broadcom-wl Wi-Fi driver (only if a Broadcom chip is found)
OPT_GRUB_BTRFS="${OPT_GRUB_BTRFS:-y}"                   #  8: build grub-btrfs (boot snapshots from the GRUB menu)
OPT_APPLY_FIRMWARE="${OPT_APPLY_FIRMWARE:-y}"           # 10: apply firmware updates (n = only list them)
OPT_ACCENT_COLOR="${OPT_ACCENT_COLOR:-y}"               # 11: bundled Accent Color Everywhere extension
OPT_APPINDICATOR="${OPT_APPINDICATOR:-y}"               # 11: tray icons (AppIndicator extension)
OPT_DASH_TO_DOCK="${OPT_DASH_TO_DOCK:-y}"               # 11: Dash to Dock
OPT_MSFONTS_EULA="${OPT_MSFONTS_EULA:-y}"               # 12: y = you accept https://corefonts.sourceforge.net/eula.htm
OPT_PROTON_GE="${OPT_PROTON_GE:-y}"                     # 14: download the latest Proton-GE into Steam
GAMING_PACKAGES="${GAMING_PACKAGES-ntsync-autoload gamemode mangohud gamescope lutris}"   # 14: installed alongside Steam
PROTON_GE_REPO="https://github.com/GloriousEggroll/proton-ge-custom"
OPT_BRAVE_LOCK_BITWARDEN="${OPT_BRAVE_LOCK_BITWARDEN:-n}"       # S: force-install Bitwarden in Brave (can't be switched off)
OPT_BRAVE_FLATHUB_FALLBACK="${OPT_BRAVE_FLATHUB_FALLBACK:-n}"   # S: if Brave Origin fails, install regular Brave from Flathub
OPT_REBOOT_WHEN_DONE="${OPT_REBOOT_WHEN_DONE:-y}"       # reboot automatically at the end if a step needs it
VMWARE_BUNDLE="${VMWARE_BUNDLE:-}"                      #  7: path to VMware-Workstation-*.bundle, used if VMware isn't installed yet
VMWARE_PATCHED_URL="${VMWARE_PATCHED_URL:-}"            #  7: git URL of patched vmmon/vmnet sources, used if the bundled ones don't build

# Extensions from extensions.gnome.org installed by step 11:  "ID | name"
# ID is the number in the extension's URL: extensions.gnome.org/extension/<ID>/…
# The build matching this GNOME Shell version is downloaded; delete a line to drop one.
GNOME_EXTENSIONS=(
  "19|User Themes"
  "517|Caffeine"
  "1319|GSConnect"
  "779|Clipboard Indicator"
  "2087|Desktop Icons NG (DING)"
  "3960|Transparent Top Bar (Adjustable transparency)"
)
EGO_STATE="/var/lib/fedora45-postinstall/ego-extensions"   # "ID uuid" for each one installed

# Desktop background set by step 11: an image kept in this repo (empty = leave the background alone)
WALLPAPER="${WALLPAPER-wallpapers/forest-fog.jpg}"

# Custom keyboard shortcuts added by step 11:  "name | command | key combination"
CUSTOM_SHORTCUTS=(
  "Resources|gnome-system-monitor|<Control><Alt>Delete"
)

# GNOME settings applied by step 11, one per line:  "schema key value"
# Schemas of installed extensions work too (looked up in the extension's folder).
GNOME_SETTINGS=(
  "org.gnome.desktop.wm.preferences button-layout 'appmenu:minimize,maximize,close'"
  "org.gnome.desktop.peripherals.touchpad tap-to-click true"
  "org.gnome.desktop.peripherals.mouse speed 0.5"                                  # pointer speed 75% (range -1 … 1)
  "org.gnome.desktop.peripherals.touchpad speed 0.5"                               # same for the touchpad
  "org.gnome.desktop.interface color-scheme 'prefer-dark'"                         # dark style
  "org.gnome.desktop.session idle-delay 900"                                       # blank the screen after 15 minutes
  "org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing'"       # no automatic suspend when plugged in
  "org.gnome.settings-daemon.plugins.media-keys logout ['<Control><Alt>l']"        # log out: Ctrl+Alt+L (frees Ctrl+Alt+Del)
  "org.gnome.desktop.interface show-battery-percentage true"
  "org.gnome.desktop.interface clock-show-weekday true"
  "org.gnome.desktop.interface enable-hot-corners false"
  "org.gnome.settings-daemon.plugins.color night-light-enabled true"
  "org.gtk.gtk4.Settings.FileChooser sort-directories-first true"
  "org.gtk.Settings.FileChooser sort-directories-first true"
  # Accent Color Everywhere - uncomment and edit (the extension's defaults are shown):
  # "org.gnome.shell.extensions.accent-color-everywhere source 'wallpaper'"       # or 'custom' / 'system'
  # "org.gnome.shell.extensions.accent-color-everywhere custom-color '#3584e4'"   # used when source is 'custom'
  # "org.gnome.shell.extensions.accent-color-everywhere gnome-palette true"       # false = exact colour
  # "org.gnome.shell.extensions.accent-color-everywhere target-border true"       # focused-window outline
  # "org.gnome.shell.extensions.accent-color-everywhere border-width 1"
)

NEED_REBOOT=0
MOK_PENDING=0
declare -A RESULT

# ---------- output helpers ---------------------------------------------------
if [[ -t 1 ]]; then
  C_B=$'\e[1m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_R=$'\e[31m'; C_C=$'\e[36m'; C_D=$'\e[2m'; C_0=$'\e[0m'
else
  C_B=; C_G=; C_Y=; C_R=; C_C=; C_D=; C_0=
fi
info() { echo "${C_C}==>${C_0} $*"; echo "[INFO] $*" >>"$LOG"; }
ok()   { echo "${C_G} ✔${C_0}  $*"; echo "[ OK ] $*" >>"$LOG"; }
warn() { echo "${C_Y} !${C_0}  $*"; echo "[WARN] $*" >>"$LOG"; }
err()  { echo "${C_R} ✘${C_0}  $*"; echo "[FAIL] $*" >>"$LOG"; }

# Run a non-interactive command, show output and append it to the log
run() {
  echo "+ $*" >>"$LOG"
  "$@" 2>&1 | tee -a "$LOG"
  return "${PIPESTATUS[0]}"
}

ask_yn() {  # ask_yn "Question" default(y/n)
  local q="$1" def="${2:-n}" ans
  local hint="[y/N]"; [[ $def == y ]] && hint="[Y/n]"
  read -rp "    $q $hint " ans
  ans="${ans:-$def}"
  [[ ${ans,,} == y* ]]
}

# Read a y/n setting from the SETTINGS block instead of asking.
opt() {  # opt OPT_NAME "what it controls"  -> true when the setting is y
  local v="${!1:-n}"
  if [[ ${v,,} == y* ]]; then info "$2: yes  ($1)"; return 0; fi
  info "$2: no  (set $1=y to enable)"; return 1
}

have() { rpm -q "$@" >/dev/null 2>&1; }   # true when every named package is installed

# ---------- pre-flight -------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
  exec sudo -E bash "$0" "$@"
fi
touch "$LOG"; chmod 600 "$LOG"
echo "===== $(date -Is) run started =====" >>"$LOG"

# shellcheck disable=SC1091
. /etc/os-release
if [[ ${ID:-} != fedora ]]; then
  err "This is not Fedora (ID=${ID:-unknown}). Aborting."; exit 1
fi
if [[ ${VERSION_ID:-} != 45 ]]; then
  warn "Written for Fedora 45; you are on Fedora ${VERSION_ID:-?}. Most steps should still work."
fi
FEDVER="$(rpm -E %fedora)"
command -v lspci >/dev/null || dnf -y install pciutils >>"$LOG" 2>&1

# ---------- shared helpers ---------------------------------------------------
secure_boot_enabled() {
  command -v mokutil >/dev/null || dnf -y install mokutil >>"$LOG" 2>&1
  mokutil --sb-state 2>/dev/null | grep -qi 'SecureBoot enabled'
}

rpmfusion_enabled() {
  rpm -q rpmfusion-free-release rpmfusion-nonfree-release >/dev/null 2>&1
}

require_rpmfusion() {
  rpmfusion_enabled || { info "RPM Fusion is required first - enabling it."; step_rpmfusion; }
}

# Create the akmods signing key (if missing) and queue MOK enrolment if needed.
# The same key signs NVIDIA/Broadcom akmods and the VMware modules.
ensure_signing_key() {
  run dnf -y install akmods mokutil openssl || return 1
  if [[ ! -f $AKMODS_CERT || ! -f $AKMODS_KEY ]]; then
    info "Generating module signing key (kmodgenca)…"
    run kmodgenca -a || { err "kmodgenca failed"; return 1; }
  fi
  if ! secure_boot_enabled; then
    info "Secure Boot is disabled - key created but enrolment not required."
    return 0
  fi
  local t; t="$(mokutil --test-key "$AKMODS_CERT" 2>&1)"
  if grep -qi 'already enrolled' <<<"$t"; then
    ok "Signing key already enrolled in MOK."
  elif grep -qi 'enrollment request' <<<"$t"; then
    ok "Signing key enrolment already queued for next boot."; MOK_PENDING=1
  else
    echo
    echo "${C_B}    Secure Boot is ON. The signing key must be enrolled in MOK.${C_0}"
    echo "    Choose a short one-time password now; you'll type it ONCE at the"
    echo "    blue 'MOK management' screen on the next reboot (Enroll MOK → Continue → Yes)."
    echo "    Note: that screen usually uses a US keyboard layout."
    echo
    if mokutil --import "$AKMODS_CERT"; then
      MOK_PENDING=1; NEED_REBOOT=1; ok "MOK enrolment queued."
    else
      err "mokutil --import failed"; return 1
    fi
  fi
}

gpu_lines() { lspci -nn | grep -Ei 'vga|3d controller|display controller'; }

# ---------- STEP 1: update ---------------------------------------------------
step_update() {
  info "Configuring DNF (10 parallel downloads)…"
  run dnf config-manager setopt max_parallel_downloads=10 || warn "Could not set dnf options"
  info "Upgrading the system (this can take a while)…"
  local before after
  before="$(rpm -q kernel-core --last | head -1 | awk '{print $1}')"
  run dnf -y upgrade --refresh || return 1
  after="$(rpm -q kernel-core --last | head -1 | awk '{print $1}')"
  if [[ $before != "$after" ]] || [[ "kernel-core-$(uname -r)" != "$after" ]]; then
    warn "A newer kernel is installed than the one running - reboot when convenient."
    NEED_REBOOT=1
  fi
  ok "System updated."
}

# ---------- STEP 2: RPM Fusion -----------------------------------------------
step_rpmfusion() {
  if rpmfusion_enabled; then
    ok "RPM Fusion free/nonfree already installed."
  else
    # Fedora 45's rpm enforces signatures, so 'rpm -i URL' fails with NOKEY.
    # dnf handles it correctly.
    info "Installing RPM Fusion free + nonfree release packages…"
    run dnf -y install \
      "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${FEDVER}.noarch.rpm" \
      "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${FEDVER}.noarch.rpm" \
      || return 1
  fi
  info "Adding RPM Fusion free-tainted (libdvdcss)…"
  run dnf -y install rpmfusion-free-release-tainted || warn "free-tainted repo not installed"
  # AppStream metadata so RPM Fusion apps appear in GNOME Software
  run dnf -y install rpmfusion-free-appstream-data rpmfusion-nonfree-appstream-data \
    || warn "AppStream metadata not installed (cosmetic)"
  ok "RPM Fusion enabled."
}

# ---------- STEP 3: codecs ---------------------------------------------------
step_codecs() {
  require_rpmfusion || return 1
  local rc=0

  info "Swapping ffmpeg-free for full ffmpeg (H.264/HEVC encoders, fdk-aac)…"
  if rpm -q ffmpeg >/dev/null 2>&1; then ok "Full ffmpeg already installed."
  else run dnf -y swap ffmpeg-free ffmpeg --allowerasing || { err "ffmpeg swap failed"; rc=1; }
  fi

  info "Installing GStreamer multimedia group…"
  # dnf5: 'install @multimedia' (not 'update @multimedia', which fails on F45)
  run dnf -y install @multimedia --setopt=install_weak_deps=False \
    --exclude=PackageKit-gstreamer-plugin || { err "@multimedia failed"; rc=1; }

  info "Installing DVD, OpenH264 and archive-format support…"
  run dnf -y install libdvdcss gstreamer1-plugin-openh264 mozilla-openh264 \
    unrar 7zip cabextract lame libva-utils || warn "Some extras failed to install"

  info "Hardware video decode (VA-API) - detecting GPU…"
  local gpus; gpus="$(gpu_lines)"; echo "$gpus" | sed 's/^/    /'
  if grep -qi intel <<<"$gpus"; then
    # Fedora 44+: install alongside, don't swap - libva prefers dri-nonfree/dri-freeworld
    run dnf -y install intel-media-driver || warn "intel-media-driver failed"
    run dnf -y install libva-intel-driver || true   # pre-Broadwell iGPUs
  fi
  if grep -Eqi 'amd|ati|radeon' <<<"$gpus" || grep -qi nvidia <<<"$gpus"; then
    # Covers AMD and Nouveau. Do NOT 'swap mesa-va-drivers' on F44+ - it breaks mesa.
    if ! run dnf -y install mesa-va-drivers-freeworld; then
      warn "mesa-va-drivers-freeworld failed - usually a Mesa version skew right after a release."
      if opt OPT_MESA_TESTING_RETRY "Retry with Fedora updates-testing enabled"; then
        run dnf -y install mesa-va-drivers-freeworld --enablerepo=updates-testing \
          || warn "Still failing - try again after the next 'dnf upgrade'."
      fi
    fi
    if grep -Eqi 'amd|ati|radeon' <<<"$gpus"; then
      run dnf -y swap mesa-vulkan-drivers mesa-vulkan-drivers-freeworld --allowerasing \
        || warn "Vulkan freeworld swap skipped"
    fi
  fi
  [[ $rc -eq 0 ]] && ok "Codecs installed. Check decode later with: vainfo"
  return $rc
}

# ---------- STEP 4: NVIDIA driver --------------------------------------------
step_nvidia() {
  local gpus br pkg v
  gpus="$(gpu_lines)"

  if grep -qi nvidia <<<"$gpus"; then
    echo "    NVIDIA GPU detected:"; grep -i nvidia <<<"$gpus" | sed 's/^/      /'
    # The one question this script asks - and only when a card is present
    ask_yn "Install the proprietary NVIDIA driver?" y || { warn "Skipping NVIDIA."; return 2; }
  else
    info "No NVIDIA GPU detected - nothing to install."; return 2
  fi
  require_rpmfusion || return 1

  echo "    Choose driver branch:"
  echo "      1) Current  - RTX 20xx / GTX 16xx (Turing) and newer"
  echo "      2) 580xx    - GTX 9xx/10xx (Maxwell, Pascal), Volta"
  echo "      3) 470xx    - GTX 6xx/7xx (Kepler)"
  echo "      s) Skip"
  read -rp "    Branch [1]: " br
  case "${br:-1}" in
    1) pkg="akmod-nvidia xorg-x11-drv-nvidia-cuda" ;;
    2) pkg="akmod-nvidia-580xx xorg-x11-drv-nvidia-580xx-cuda" ;;
    3) pkg="akmod-nvidia-470xx xorg-x11-drv-nvidia-470xx-cuda" ;;
    *) warn "Skipping NVIDIA."; return 2 ;;
  esac

  ensure_signing_key || return 1   # key must exist BEFORE akmods builds
  run dnf -y install kernel-devel-matched || true
  # shellcheck disable=SC2086
  run dnf -y install $pkg libva-nvidia-driver || return 1
  info "Building NVIDIA module now (akmods), a few minutes…"
  run akmods --force --kernels "$(uname -r)" || warn "akmods reported errors (see $LOG)"
  if v="$(modinfo -F version nvidia 2>/dev/null)"; then ok "NVIDIA module $v built."
  else warn "NVIDIA module not found yet - akmods will retry at boot."; fi
  NEED_REBOOT=1
}

# ---------- STEP 5: other drivers & firmware ---------------------------------
step_drivers() {
  require_rpmfusion || return 1
  local did=0 net
  net="$(lspci -nn | grep -i 'network controller')"

  if grep -qi broadcom <<<"$net"; then
    did=1
    echo; echo "    Broadcom Wi-Fi detected:"; grep -i broadcom <<<"$net" | sed 's/^/      /'
    echo "    Only BCM43xx chips unsupported by brcmfmac/b43 need the 'wl' driver."
    if opt OPT_BROADCOM_WL "Proprietary broadcom-wl driver (akmod-wl)"; then
      ensure_signing_key || return 1
      run dnf -y install broadcom-wl akmod-wl || return 1
      run akmods --force --kernels "$(uname -r)" || true
      NEED_REBOOT=1
    fi
  fi

  info "Installing extra firmware…"
  run dnf -y install linux-firmware intel-gpu-firmware amd-gpu-firmware \
    nvidia-gpu-firmware alsa-sof-firmware 2>/dev/null || true

  [[ $did -eq 0 ]] && info "No Broadcom Wi-Fi needing the proprietary driver found."
  ok "Driver/firmware step complete."
}

# ---------- STEP 6: build tools ---------------------------------------------
step_devtools() {
  info "Installing GCC, make and kernel headers/devel…"
  run dnf -y install gcc gcc-c++ make kernel-headers kernel-devel-matched \
    elfutils-libelf-devel dwarves perl openssl git patch bc || return 1
  # Headers for the *running* kernel too, if it's still in the repos
  run dnf -y install "kernel-devel-$(uname -r)" \
    || warn "kernel-devel for running kernel $(uname -r) not available - reboot into the newest kernel."
  if [[ -d /lib/modules/$(uname -r)/build ]]; then
    ok "Build tools ready for kernel $(uname -r)."
  else
    warn "No build tree for running kernel - reboot, then rerun step 7."
  fi
}

# ---------- STEP 7: VMware modules ------------------------------------------
write_vmware_helper() {
  install -d /usr/local/sbin
  cat >"$VMW_HELPER" <<'HELPER'
#!/usr/bin/env bash
# vmware-modules-build: build, install and sign vmmon/vmnet for one or more kernels.
# Usage: vmware-modules-build [--if-missing] [KVER ...]   (default: every kernel with a build tree)
# Source: patched tree in /usr/local/src/vmware-host-modules if present,
#         otherwise VMware's bundled /usr/lib/vmware/modules/source/*.tar
set -uo pipefail
LOG=/var/log/vmware-modules-build.log
KEY=/etc/pki/akmods/private/private_key.priv
CERT=/etc/pki/akmods/certs/public_key.der
PATCHED=/usr/local/src/vmware-host-modules
BUNDLED=/usr/lib/vmware/modules/source
IF_MISSING=0
[[ ${1:-} == --if-missing ]] && { IF_MISSING=1; shift; }

kvers=("$@")
if [[ ${#kvers[@]} -eq 0 ]]; then
  for d in /lib/modules/*/build; do [[ -e $d ]] && kvers+=("$(basename "$(dirname "$d")")"); done
fi

build_one() {
  local kver=$1 tmp m ko signer fail=0
  if [[ $IF_MISSING -eq 1 && -f /lib/modules/$kver/misc/vmmon.ko && -f /lib/modules/$kver/misc/vmnet.ko ]]; then
    return 0
  fi
  [[ -d /lib/modules/$kver/build ]] || { echo "[$kver] no kernel-devel, skipping"; return 1; }
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN
  if [[ -d $PATCHED/vmmon-only && -d $PATCHED/vmnet-only ]]; then
    cp -a "$PATCHED/vmmon-only" "$PATCHED/vmnet-only" "$tmp/"
    echo "[$kver] using patched sources from $PATCHED"
  elif [[ -f $BUNDLED/vmmon.tar && -f $BUNDLED/vmnet.tar ]]; then
    tar -xf "$BUNDLED/vmmon.tar" -C "$tmp" && tar -xf "$BUNDLED/vmnet.tar" -C "$tmp"
    echo "[$kver] using VMware bundled sources"
  else
    echo "[$kver] no VMware module sources found - is VMware Workstation installed?"; return 1
  fi
  signer=/lib/modules/$kver/build/scripts/sign-file
  for m in vmmon vmnet; do
    echo "[$kver] building $m…"
    if ! make -C "$tmp/$m-only" VM_UNAME="$kver" -j"$(nproc)" >>"$LOG" 2>&1; then
      echo "[$kver] $m FAILED to build (see $LOG)"; fail=1; continue
    fi
    ko=$(find "$tmp" -name "$m.ko" -print -quit)
    [[ -z $ko && -f $tmp/$m.o ]] && ko=$tmp/$m.o     # VMware's Makefile copies the .ko to ../$m.o
    [[ -n $ko ]] || { echo "[$kver] $m.ko not produced"; fail=1; continue; }
    install -D -m 0644 "$ko" "/lib/modules/$kver/misc/$m.ko"
    if [[ -f $KEY && -f $CERT && -x $signer ]]; then
      "$signer" sha256 "$KEY" "$CERT" "/lib/modules/$kver/misc/$m.ko" && echo "[$kver] $m signed"
    else
      echo "[$kver] $m NOT signed (no key or sign-file) - fine if Secure Boot is off"
    fi
  done
  command -v restorecon >/dev/null && restorecon -R "/lib/modules/$kver/misc" 2>/dev/null
  depmod -a "$kver"
  return $fail
}

rc=0
for k in "${kvers[@]}"; do build_one "$k" 2>&1 | tee -a "$LOG"; [[ ${PIPESTATUS[0]} -eq 0 ]] || rc=1; done
running=$(uname -r)
if printf '%s\n' "${kvers[@]}" | grep -qx "$running" && [[ -f /lib/modules/$running/misc/vmmon.ko ]]; then
  modprobe -r vmnet vmmon 2>/dev/null; modprobe vmmon && modprobe vmnet || rc=1
fi
exit $rc
HELPER
  chmod 755 "$VMW_HELPER"
}

write_vmware_autorebuild() {
  # 1) Rebuild when a new kernel is installed (runs inside the dnf transaction)
  install -d /etc/kernel/install.d
  cat >"$VMW_HOOK" <<HOOK
#!/bin/sh
# Rebuild + sign VMware vmmon/vmnet whenever a kernel is installed.
[ "\$1" = "add" ] || exit 0
[ -x $VMW_HELPER ] || exit 0
$VMW_HELPER "\$2" >/dev/null 2>&1 || echo "vmware-modules: build failed for \$2 - see /var/log/vmware-modules-build.log" >&2
exit 0
HOOK
  chmod 755 "$VMW_HOOK"

  # 2) Safety net at boot, in case the hook ran before kernel-devel was present
  cat >"$VMW_SERVICE" <<UNIT
[Unit]
Description=Build VMware vmmon/vmnet for the running kernel if missing
Before=vmware.service
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c '$VMW_HELPER --if-missing "\$(uname -r)"'

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable vmware-modules-check.service >>"$LOG" 2>&1
}

step_vmware() {
  if [[ ! -f /usr/lib/vmware/modules/source/vmmon.tar ]]; then
    warn "VMware Workstation Pro does not appear to be installed."
    local bundle="$VMWARE_BUNDLE"
    [[ -z $bundle ]] && { warn "Set VMWARE_BUNDLE to the installer's path to install it here - skipping."; return 2; }
    [[ -f $bundle ]] || { err "File not found: $bundle"; return 1; }
    info "Running the VMware installer (you'll need to accept its licence)…"
    sh "$bundle" || { err "VMware installer failed"; return 1; }
  fi

  # Prerequisites
  rpm -q gcc make >/dev/null 2>&1 && [[ -d /lib/modules/$(uname -r)/build ]] || step_devtools || return 1
  if secure_boot_enabled; then
    info "Secure Boot is enabled - modules will be signed."
  fi
  # Always create the key: harmless with SB off, and ready if you turn SB on later
  ensure_signing_key || return 1

  write_vmware_helper
  info "Building vmmon/vmnet for all installed kernels with headers…"
  if ! "$VMW_HELPER"; then
    warn "Build with VMware's bundled sources failed (common on brand-new kernels)."
    echo "    Set VMWARE_PATCHED_URL to a community-patched source tree (git) containing"
    echo "    vmmon-only/ and vmnet-only/. This is third-party kernel code - review it first."
    local url="$VMWARE_PATCHED_URL"
    if [[ -n $url ]]; then
      rm -rf "$VMW_PATCHED_SRC"
      run git clone --depth 1 "$url" "$VMW_PATCHED_SRC" || return 1
      "$VMW_HELPER" || { err "Patched build also failed - see /var/log/vmware-modules-build.log"; return 1; }
    else
      return 1
    fi
  fi

  write_vmware_autorebuild
  systemctl restart vmware.service >>"$LOG" 2>&1 || /etc/init.d/vmware restart >>"$LOG" 2>&1 || true

  if secure_boot_enabled && [[ $MOK_PENDING -eq 1 ]]; then
    warn "Modules are signed but the key isn't enrolled yet - VMware will work after the MOK reboot."
    NEED_REBOOT=1
  fi
  ok "VMware modules built$(secure_boot_enabled && echo ', signed') and set to rebuild on kernel updates."
}

# ---------- helpers for running things as the desktop user -------------------
desktop_user() { [[ -n ${SUDO_USER:-} && ${SUDO_USER} != root ]] && echo "$SUDO_USER"; }
user_home() { local u; u="$(desktop_user)" || return 1; getent passwd "$u" | cut -d: -f6; }
extension_installed() {   # extension_installed UUID - for the desktop user or system-wide
  local home
  if home="$(user_home)" && [[ -f $home/.local/share/gnome-shell/extensions/$1/metadata.json ]]; then
    return 0
  fi
  [[ -f /usr/share/gnome-shell/extensions/$1/metadata.json ]]
}
ego_uuid() { awk -v id="$1" '$1==id {print $2; exit}' "$EGO_STATE" 2>/dev/null; }   # uuid recorded for an EGO ID
as_user() {   # run a command inside the desktop user's session (for gsettings etc.)
  local u uid; u="$(desktop_user)" || return 1; uid="$(id -u "$u")"
  sudo -u "$u" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
    XDG_RUNTIME_DIR="/run/user/$uid" "$@"
}
flathub_enabled() { flatpak remotes --columns=name 2>/dev/null | grep -qx flathub; }

# ---------- STEP 8: Btrfs snapshots ------------------------------------------
step_snapshots() {
  if [[ $(findmnt -n -o FSTYPE /) != btrfs ]]; then
    warn "Root filesystem is not Btrfs - snapshots skipped."; return 2
  fi
  info "Installing snapper and the dnf5 actions plugin…"
  run dnf -y install snapper libdnf5-plugin-actions || return 1
  run dnf -y install btrfs-assistant || warn "btrfs-assistant (GUI for browsing/restoring snapshots) not installed"

  if ! snapper -c root get-config >/dev/null 2>&1; then
    run snapper -c root create-config / || return 1
  fi
  # Snapshots on dnf transactions only - no hourly timeline eating disk space
  run snapper -c root set-config TIMELINE_CREATE=no NUMBER_LIMIT=10 NUMBER_LIMIT_IMPORTANT=5 || true
  if u="$(desktop_user)"; then
    run snapper -c root set-config "ALLOW_USERS=$u" SYNC_ACL=yes || true
  fi
  run systemctl enable --now snapper-cleanup.timer || true

  # Snapshot before every dnf transaction (dnf5 actions plugin)
  install -d /etc/dnf/libdnf5-plugins/actions.d
  cat >/etc/dnf/libdnf5-plugins/actions.d/snapper.actions <<'ACT'
# Take a snapper snapshot of / before every dnf transaction
pre_transaction::::/usr/bin/snapper -c root create -c number -d dnf-transaction
ACT
  ok "dnf will snapshot / before every transaction."

  run snapper -c root create -c important -d "baseline before fedora45-postinstall" \
    && ok "Baseline snapshot taken."

  echo
  echo "    grub-btrfs adds a 'Fedora snapshots' submenu to GRUB so you can boot a"
  echo "    snapshot if an update breaks the desktop. It's not in Fedora's repos, so it"
  echo "    is built from upstream source (github.com/Antynea/grub-btrfs)."
  echo "    Caveat: Fedora's /boot is separate ext4, so a snapshot boots with the"
  echo "    CURRENT kernel - fine for recovering from a bad package, not a bad kernel."
  if opt OPT_GRUB_BTRFS "Install grub-btrfs"; then
    run dnf -y install git make inotify-tools || return 1
    rm -rf /usr/local/src/grub-btrfs
    run git clone --depth 1 https://github.com/Antynea/grub-btrfs /usr/local/src/grub-btrfs || return 1
    local cfg=/usr/local/src/grub-btrfs/config
    sed -i \
      -e 's|^#\?GRUB_BTRFS_GRUB_DIRNAME=.*|GRUB_BTRFS_GRUB_DIRNAME="/boot/grub2"|' \
      -e 's|^#\?GRUB_BTRFS_MKCONFIG=.*|GRUB_BTRFS_MKCONFIG=/usr/sbin/grub2-mkconfig|' \
      -e 's|^#\?GRUB_BTRFS_SCRIPT_CHECK=.*|GRUB_BTRFS_SCRIPT_CHECK=grub2-script-check|' "$cfg"
    run make -C /usr/local/src/grub-btrfs install || return 1
    run grub2-mkconfig -o /boot/grub2/grub.cfg || warn "grub2-mkconfig reported errors"
    run systemctl enable --now grub-btrfsd || warn "grub-btrfsd service not started"
    ok "grub-btrfs installed."
  fi
}

# ---------- STEP 9: Flathub --------------------------------------------------
step_flathub() {
  run dnf -y install flatpak fedora-third-party || return 1
  # Enables full Flathub plus Fedora's curated third-party repos (Chrome, Steam, NVIDIA)
  run fedora-third-party enable || warn "fedora-third-party enable failed"
  run flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo || return 1
  run flatpak remote-modify --enable flathub || true
  flathub_enabled && ok "Flathub enabled ($(flatpak remote-ls flathub --app --columns=application 2>/dev/null | wc -l) apps visible)."
}

# ---------- STEP 10: firmware ------------------------------------------------
step_firmware() {
  run dnf -y install fwupd || return 1
  run fwupdmgr refresh --force || warn "Could not refresh LVFS metadata"
  echo
  local out; out="$(fwupdmgr get-updates 2>&1)"; echo "$out" | sed 's/^/    /'; echo "$out" >>"$LOG"
  if grep -Eqi 'no updat|no upgrades|no updatable' <<<"$out"; then
    ok "Firmware is up to date."; return 0
  fi
  if grep -qi discharging /sys/class/power_supply/BAT*/status 2>/dev/null; then
    warn "Running on battery - many firmware updates are refused. Plug into AC first."
  fi
  if opt OPT_APPLY_FIRMWARE "Apply the firmware updates listed above"; then
    fwupdmgr update -y --no-reboot-check || { err "fwupdmgr update failed"; return 1; }
    NEED_REBOOT=1
  else
    return 2
  fi
}

# ---------- STEP 11: GNOME tweaks -------------------------------------------
add_extension() {   # enable a GNOME extension for the desktop user (takes effect at next login)
  local uuid=$1 cur
  cur="$(as_user gsettings get org.gnome.shell enabled-extensions 2>/dev/null)" || return 1
  grep -q "'$uuid'" <<<"$cur" && return 0
  if [[ $cur == "@as []" || $cur == "[]" ]]; then cur="['$uuid']"; else cur="${cur%]}, '$uuid']"; fi
  as_user gsettings set org.gnome.shell enabled-extensions "$cur"
}

# Copy an unpacked extension (folder SRC containing metadata.json) into place
# for the desktop user, or system-wide if the script wasn't started via sudo.
deploy_extension() {   # deploy_extension UUID SRC
  local uuid=$1 src=$2 dest u home
  if u="$(desktop_user)"; then
    home="$(getent passwd "$u" | cut -d: -f6)"
    dest="$home/.local/share/gnome-shell/extensions/$uuid"
  else
    u=""; dest="/usr/share/gnome-shell/extensions/$uuid"
  fi

  if [[ -e $dest/.git ]]; then
    # A git checkout there is a working copy - never overwrite it
    warn "$dest is a git checkout - leaving it untouched."; return 0
  fi
  if [[ -n $u ]]; then
    sudo -u "$u" mkdir -p "$dest" || { err "Could not create $dest"; return 1; }
  else
    install -d "$dest"
  fi
  find "$dest" -mindepth 1 -delete            # clear any previous copy
  cp -r --preserve=mode,timestamps "$src/." "$dest/" || { err "Copy to $dest failed"; return 1; }
  if [[ -d $dest/schemas ]] && command -v glib-compile-schemas >/dev/null; then
    glib-compile-schemas "$dest/schemas" >>"$LOG" 2>&1 || warn "Could not recompile the extension's settings schema"
  fi
  [[ -n $u ]] && chown -R "$u:" "$dest"
  command -v restorecon >/dev/null && restorecon -R "$dest" 2>/dev/null
  ok "Installed $uuid to $dest."
}

# Install one extension from extensions.gnome.org by the number in its URL.
install_ego_extension() {   # install_ego_extension ID "Name"
  local id=$1 name=$2 shellver json uuid url tmp rc=0
  uuid="$(ego_uuid "$id")"
  if [[ -n $uuid ]] && extension_installed "$uuid"; then
    ok "$name already installed."; EXT_ADD+=("$uuid"); return 0
  fi
  shellver="$(gnome-shell --version 2>/dev/null | grep -oE '[0-9]+' | head -1)"
  [[ -n $shellver ]] || { err "Can't tell the GNOME Shell version - is gnome-shell installed?"; return 1; }
  command -v curl >/dev/null && command -v unzip >/dev/null || run dnf -y install curl unzip || return 1

  info "$name: looking up the build for GNOME Shell $shellver…"
  json="$(curl -fsSL --retry 2 "https://extensions.gnome.org/extension-info/?pk=$id&shell_version=$shellver" 2>>"$LOG")" \
    || { warn "$name: extensions.gnome.org has no build for GNOME Shell $shellver (or can't be reached)."; return 1; }
  uuid="$(grep -oE '"uuid": *"[^"]+"' <<<"$json" | head -1 | cut -d'"' -f4)"
  url="$(grep -oE '"download_url": *"[^"]+"' <<<"$json" | head -1 | cut -d'"' -f4)"; url="${url//\\/}"
  if [[ ! $uuid =~ ^[A-Za-z0-9._-]+@[A-Za-z0-9._-]+$ || $url != /download-extension/* ]]; then
    err "$name: unexpected answer from extensions.gnome.org for ID $id."; return 1
  fi

  tmp="$(mktemp -d)"
  if curl -fsSL --retry 2 -o "$tmp/ext.zip" "https://extensions.gnome.org$url" 2>>"$LOG" \
     && unzip -q -o "$tmp/ext.zip" -d "$tmp/ext" >>"$LOG" 2>&1 \
     && grep -qF "\"$uuid\"" "$tmp/ext/metadata.json" 2>/dev/null; then
    deploy_extension "$uuid" "$tmp/ext" || rc=1
  else
    err "$name: download or unpack failed."; rc=1
  fi
  rm -rf "$tmp"
  [[ $rc -eq 0 ]] || return 1

  install -d "$(dirname "$EGO_STATE")"
  { grep -v "^$id " "$EGO_STATE" 2>/dev/null; echo "$id $uuid"; } >"$EGO_STATE.new" && mv "$EGO_STATE.new" "$EGO_STATE"
  EXT_ADD+=("$uuid")
}

# Install a GNOME extension bundled in this repo (extensions/<uuid>/).
install_bundled_extension() {
  local uuid=$1 src="$SCRIPT_DIR/extensions/$1" tmp="" shellver rc=0

  if [[ ! -f $src/metadata.json ]]; then
    info "extensions/$uuid is not next to this script - fetching it from GitHub…"
    command -v curl >/dev/null && command -v tar >/dev/null || run dnf -y install curl tar || return 1
    tmp="$(mktemp -d)"
    if ! curl -fsSL --retry 3 "$REPO_TARBALL" \
         | tar -xz -C "$tmp" --strip-components=1 --wildcards "*/extensions/$uuid/*" 2>>"$LOG"; then
      err "Could not download $uuid from $REPO_TARBALL"; rm -rf "$tmp"; return 1
    fi
    src="$tmp/extensions/$uuid"
  fi
  if ! grep -q "\"uuid\": *\"$uuid\"" "$src/metadata.json" 2>/dev/null; then
    err "$src does not look like the $uuid extension."; [[ -n $tmp ]] && rm -rf "$tmp"; return 1
  fi

  # Warn (don't block) if this GNOME Shell version isn't one the extension declares
  shellver="$(gnome-shell --version 2>/dev/null | grep -oE '[0-9]+' | head -1)"
  if [[ -n $shellver ]] && ! grep -q "\"$shellver\"" "$src/metadata.json"; then
    warn "$uuid doesn't list GNOME Shell $shellver as supported - it may refuse to load."
  fi

  deploy_extension "$uuid" "$src" || rc=1
  [[ -n $tmp ]] && rm -rf "$tmp"
  return $rc
}

# Copy the WALLPAPER image from this repo into the user's backgrounds folder and set it.
install_wallpaper() {
  [[ -n $WALLPAPER ]] || return 0
  local src="$SCRIPT_DIR/$WALLPAPER" name="${WALLPAPER##*/}" u home dest tmp="" rc=0
  u="$(desktop_user)" && home="$(user_home)" || return 1
  if [[ ! -f $src ]]; then
    info "$WALLPAPER is not next to this script - fetching it from GitHub…"
    tmp="$(mktemp -d)"; src="$tmp/$name"
    curl -fsSL --retry 3 -o "$src" "$REPO_RAW/$WALLPAPER" 2>>"$LOG" \
      || { warn "Could not download the wallpaper - background left unchanged."; rm -rf "$tmp"; return 1; }
  fi
  dest="$home/.local/share/backgrounds/$name"
  if sudo -u "$u" mkdir -p "${dest%/*}" && install -m 0644 -o "$u" -g "$(id -gn "$u")" "$src" "$dest"; then
    command -v restorecon >/dev/null && restorecon "$dest" 2>/dev/null
    if as_user gsettings set org.gnome.desktop.background picture-uri "'file://$dest'" >>"$LOG" 2>&1 \
       && as_user gsettings set org.gnome.desktop.background picture-uri-dark "'file://$dest'" >>"$LOG" 2>&1 \
       && as_user gsettings set org.gnome.desktop.background picture-options "'zoom'" >>"$LOG" 2>&1; then
      ok "Desktop background set to $dest."
    else
      warn "Wallpaper copied to $dest but could not be set (not in a GNOME session?)."; rc=1
    fi
  else
    warn "Could not copy the wallpaper to $dest."; rc=1
  fi
  [[ -n $tmp ]] && rm -rf "$tmp"
  return $rc
}

# Add the CUSTOM_SHORTCUTS table to GNOME's custom keyboard shortcuts.
# A shortcut with the same name is updated in place; others are left alone.
apply_custom_shortcuts() {
  local schema=org.gnome.settings-daemon.plugins.media-keys
  local base=/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings
  local row name cmd binding exe list p path i
  for row in "${CUSTOM_SHORTCUTS[@]}"; do
    IFS='|' read -r name cmd binding <<<"$row"
    [[ -n $name && -n $cmd && -n $binding ]] || { warn "Ignoring malformed shortcut: $row"; continue; }
    exe="${cmd%% *}"
    if ! command -v "$exe" >/dev/null; then
      run dnf -y install "/usr/bin/$exe" \
        || warn "'$exe' is not installed - the '$name' shortcut won't do anything until it is."
    fi
    list="$(as_user gsettings get "$schema" custom-keybindings 2>/dev/null)" \
      || { warn "Could not read the keyboard shortcuts (not in a GNOME session?)."; return 1; }
    path=""
    for p in $(grep -oE "$base/[^']+/" <<<"$list"); do
      if [[ "$(as_user gsettings get "$schema.custom-keybinding:$p" name 2>/dev/null)" == "'$name'" ]]; then path=$p; break; fi
    done
    if [[ -z $path ]]; then
      i=0; while grep -qF "$base/custom$i/" <<<"$list"; do i=$((i+1)); done
      path="$base/custom$i/"
      if [[ $list == "@as []" || $list == "[]" ]]; then list="['$path']"; else list="${list%]}, '$path']"; fi
      as_user gsettings set "$schema" custom-keybindings "$list" >>"$LOG" 2>&1 \
        || { warn "Could not add the '$name' shortcut."; continue; }
    fi
    if as_user gsettings set "$schema.custom-keybinding:$path" name "'$name'" >>"$LOG" 2>&1 \
       && as_user gsettings set "$schema.custom-keybinding:$path" command "'$cmd'" >>"$LOG" 2>&1 \
       && as_user gsettings set "$schema.custom-keybinding:$path" binding "'$binding'" >>"$LOG" 2>&1; then
      ok "Shortcut '$name': $binding runs '$cmd'."
    else
      warn "Could not set the '$name' shortcut."
    fi
  done
}

# Apply the GNOME_SETTINGS table for the desktop user.
apply_gnome_settings() {
  local line schema key value file home n=0 bad=0
  local -a args
  home="$(user_home)" || return 1
  for line in "${GNOME_SETTINGS[@]}"; do
    read -r schema key value <<<"$line"
    [[ -n $schema && -n $key && -n $value ]] || { warn "Ignoring malformed GNOME setting: $line"; continue; }
    args=()
    if [[ $schema == org.gnome.shell.extensions.* ]]; then
      # Extension schemas live in the extension's own folder, not the system one
      file="$(compgen -G "$home/.local/share/gnome-shell/extensions/*/schemas/$schema.gschema.xml" | head -1)"
      [[ -n $file ]] || file="$(compgen -G "/usr/share/gnome-shell/extensions/*/schemas/$schema.gschema.xml" | head -1)"
      [[ -n $file ]] && args=(--schemadir "${file%/*}")
    fi
    if as_user gsettings "${args[@]}" set "$schema" "$key" "$value" >>"$LOG" 2>&1; then
      n=$((n+1))
    else
      warn "Could not set $schema $key"; bad=$((bad+1))
    fi
  done
  if [[ $bad -eq 0 ]]; then ok "Applied $n GNOME settings."
  else warn "Applied $n GNOME settings, $bad failed (not in a GNOME session, or a key doesn't exist on this version)."; fi
}

step_gnome() {
  run dnf -y install gnome-tweaks || return 1

  echo "    Accent Color Everywhere applies one accent colour (from the wallpaper, a"
  echo "    colour you pick, or GNOME Settings) to the Shell, GTK 3/4, Qt apps and icons."
  if opt OPT_ACCENT_COLOR "Bundled Accent Color Everywhere extension"; then
    install_bundled_extension "$ACCENT_UUID" && EXT_ADD+=("$ACCENT_UUID")
  fi

  if opt OPT_APPINDICATOR "AppIndicator support (tray icons for Discord, Nextcloud, Steam…)"; then
    run dnf -y install gnome-shell-extension-appindicator && EXT_ADD+=("appindicatorsupport@rgcjonas.gmail.com")
  fi
  if opt OPT_DASH_TO_DOCK "Dash to Dock (always-visible dock)"; then
    run dnf -y install gnome-shell-extension-dash-to-dock && EXT_ADD+=("dash-to-dock@micxgx.gmail.com")
  fi
  local row id name
  for row in "${GNOME_EXTENSIONS[@]}"; do
    IFS='|' read -r id name <<<"$row"
    install_ego_extension "$id" "$name" || warn "$name was not installed."
  done

  flathub_enabled || step_flathub
  run flatpak install -y --noninteractive flathub com.mattjakeman.ExtensionManager \
    || warn "Extension Manager not installed"

  if desktop_user >/dev/null; then
    apply_gnome_settings
    apply_custom_shortcuts
    install_wallpaper
    local e; for e in "${EXT_ADD[@]}"; do add_extension "$e" || warn "Could not enable $e"; done
    [[ ${#EXT_ADD[@]} -gt 0 ]] && info "Extensions enable at your next log-in (Wayland can't reload the shell)."
  else
    warn "Run the script via sudo from your desktop session to apply per-user GNOME settings."
  fi
  ok "GNOME tweaks done."
}
EXT_ADD=()

# ---------- STEP 12: Microsoft core fonts -----------------------------------
step_msfonts() {
  local dest=/usr/share/fonts/msttcore
  if [[ -f $dest/arial.ttf ]]; then ok "Microsoft core fonts already installed."; return 0; fi
  echo "    Installs Arial, Times New Roman, Verdana, Georgia, Courier New, Comic Sans,"
  echo "    Impact, Trebuchet, Andale Mono and Webdings from the original corefonts"
  echo "    packages on SourceForge. Fonts are extracted with cabextract; no third-party"
  echo "    RPM or install scripts are run. They are covered by Microsoft's EULA:"
  echo "    https://corefonts.sourceforge.net/eula.htm"
  opt OPT_MSFONTS_EULA "Microsoft core fonts EULA accepted" || return 2

  run dnf -y install cabextract curl fontconfig || return 1
  local tmp f fail=0; tmp="$(mktemp -d)"
  for f in andale32 arial32 arialb32 comic32 courie32 georgi32 impact32 times32 trebuc32 verdan32 webdin32; do
    if curl -fsSL --retry 3 -o "$tmp/$f.exe" "https://downloads.sourceforge.net/corefonts/$f.exe"; then
      cabextract -q -L -F '*.ttf' -d "$tmp/ttf" "$tmp/$f.exe" >>"$LOG" 2>&1 || fail=1
    else
      warn "Download failed: $f.exe"; fail=1
    fi
  done
  if compgen -G "$tmp/ttf/*.ttf" >/dev/null; then
    install -d "$dest" && install -m 0644 "$tmp"/ttf/*.ttf "$dest/"
    command -v restorecon >/dev/null && restorecon -R "$dest"
    fc-cache -f "$dest" >>"$LOG" 2>&1
    ok "Installed $(find "$dest" -name '*.ttf' | wc -l) font files to $dest."
  else
    err "No fonts extracted."; fail=1
  fi
  rm -rf "$tmp"
  return $fail
}

# ---------- STEP 13: OpenSSL 3 compat ---------------------------------------
step_openssl3() {
  # Fedora 45 moved to OpenSSL 4; vendor binaries (VS Code's extension signer,
  # older proprietary apps) still link libssl.so.3.
  run dnf -y install openssl3-libs || return 1
  ok "OpenSSL 3 compatibility libraries installed."
}

# ---------- STEP 14: gaming ---------------------------------------------------
# Download the newest GE-Proton release into Steam's compatibilitytools.d,
# verified against the checksum published with it.
install_proton_ge() {
  local u home ctd tag base tmp name found="" top="" rc=0
  u="$(desktop_user)" && home="$(user_home)" || { warn "No desktop user (run via sudo) - Proton-GE skipped."; return 1; }
  ctd="$home/.local/share/Steam/compatibilitytools.d"
  command -v curl >/dev/null || run dnf -y install curl || return 1

  # The "latest" page redirects to .../releases/tag/<name>
  tag="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "$PROTON_GE_REPO/releases/latest" 2>>"$LOG")"; tag="${tag##*/}"
  if [[ ! $tag =~ ^GE-Proton[0-9]+-[0-9]+$ ]]; then
    warn "Could not work out the latest Proton-GE release (got '${tag:-nothing}')."; return 1
  fi
  if compgen -G "$ctd/$tag*" >/dev/null; then ok "Proton-GE $tag already installed."; return 0; fi

  info "Downloading Proton-GE $tag (about 550 MB)…"
  base="$PROTON_GE_REPO/releases/download/$tag"
  tmp="$(mktemp -d -p /var/tmp)"            # /var/tmp is on disk; /tmp is RAM on Fedora
  # Proton 11 onwards names its files per architecture (GE-Proton11-12-x86_64.tar.gz);
  # earlier releases have no suffix. Try the new name first.
  for name in "$tag-$(uname -m)" "$tag"; do
    if curl -fsSL --retry 3 -o "$tmp/$name.sha512sum" "$base/$name.sha512sum" 2>>"$LOG"; then found=$name; break; fi
  done
  if [[ -n $found ]] && curl -fsSL --retry 3 -o "$tmp/$found.tar.gz" "$base/$found.tar.gz" 2>>"$LOG"; then
    if (cd "$tmp" && sha512sum -c "$found.sha512sum" >>"$LOG" 2>&1); then
      top="$(tar -tzf "$tmp/$found.tar.gz" 2>/dev/null | head -1 | cut -d/ -f1)"   # folder the archive unpacks to
      if [[ $top == GE-Proton* ]] && sudo -u "$u" mkdir -p "$ctd" \
         && tar -xzf "$tmp/$found.tar.gz" -C "$ctd" --no-same-owner && chown -R "$u:" "$ctd/$top"; then
        :
      else
        err "Could not unpack Proton-GE into $ctd."; [[ $top == GE-Proton* ]] && rm -rf "${ctd:?}/$top"; rc=1
      fi
    else
      err "Proton-GE $tag failed its checksum - not installed."; rc=1
    fi
  else
    warn "Could not download Proton-GE $tag (see $LOG)."; rc=1
  fi
  rm -rf "$tmp"
  [[ $rc -eq 0 ]] && ok "Proton-GE $tag installed - pick it in Steam under Settings > Compatibility (restart Steam first)."
  return $rc
}

proton_ge_installed() {
  local home; home="$(user_home)" || return 1
  compgen -G "$home/.local/share/Steam/compatibilitytools.d/GE-Proton*" >/dev/null
}

step_gaming() {
  require_rpmfusion || return 1
  local u pkg rc=0

  info "Installing Steam (RPM Fusion)…"
  run dnf -y install steam || { err "Steam could not be installed."; return 1; }

  # Steam is 32-bit: with the proprietary NVIDIA driver it needs the matching 32-bit libraries
  if have akmod-nvidia; then pkg=xorg-x11-drv-nvidia-libs.i686
  elif have akmod-nvidia-580xx; then pkg=xorg-x11-drv-nvidia-580xx-libs.i686
  elif have akmod-nvidia-470xx; then pkg=xorg-x11-drv-nvidia-470xx-libs.i686
  else pkg=""; fi
  if [[ -n $pkg ]]; then
    run dnf -y install "$pkg" || { warn "$pkg not installed - Steam games may not find the NVIDIA driver."; rc=1; }
  fi

  info "Installing gaming extras: $GAMING_PACKAGES"
  # shellcheck disable=SC2086
  if ! run dnf -y install $GAMING_PACKAGES; then
    warn "Installing them together failed - trying one at a time."
    for pkg in $GAMING_PACKAGES; do
      run dnf -y install "$pkg" || { warn "$pkg could not be installed."; rc=1; }
    done
  fi

  # GameMode only lets members of its group change CPU governor and priorities
  if u="$(desktop_user)" && getent group gamemode >/dev/null; then
    if id -nG "$u" | tr ' ' '\n' | grep -qx gamemode; then :
    else run usermod -aG gamemode "$u" && info "Added $u to the gamemode group (takes effect at next log-in)."; fi
  fi

  # ProtonUp-Qt: GUI for adding, updating and removing Proton-GE versions later
  flathub_enabled || step_flathub
  run flatpak install -y --noninteractive flathub net.davidotek.pupgui2 || { warn "ProtonUp-Qt not installed."; rc=1; }

  if opt OPT_PROTON_GE "Install the latest Proton-GE"; then
    install_proton_ge || rc=1
  fi

  [[ $rc -eq 0 ]] && ok "Gaming set-up done. Per-game launch options: gamemoderun mangohud %command%"
  return $rc
}

# =============================================================================
#  SOFTWARE SUBMENU  (S)
#  Rule: dnf/rpm first, Flathub as fallback - unless an app is Flathub-only.
# =============================================================================
declare -A SW_RESULT

# One line per app:   key | menu label | dnf package(s) | Flathub app ID
#   dnf is tried first, then Flathub; leave either field empty to skip it.
#   To add an ordinary app, add a line - nothing else is needed.
#   Optional hooks, picked up by name when they exist:
#     sw_pre_<key>       runs first (add a repo…); non-zero = skip the dnf attempt
#     sw_post_<key>      runs after a successful install
#     sw_fallback_<key>  runs if neither dnf nor Flathub worked
#     sw_status_<key>    extra "is it installed?" check for the menu
SOFTWARE=(
  "brave|Brave Origin + Bitwarden extension (policy)|brave-origin|"
  "qbittorrent|qBittorrent|qbittorrent|org.qbittorrent.qBittorrent"
  "vlc|VLC media player|vlc|org.videolan.VLC"
  "bitwarden|Bitwarden (Flathub)||com.bitwarden.desktop"
  "mullvad|Mullvad VPN (Mullvad repo)|mullvad-vpn|"
  "vscode|VS Code (Microsoft repo)|code|com.visualstudio.code"
  "claude_code|Claude Code (Anthropic repo)|claude-code|"
  "extmanager|Extension Manager (Flathub)||com.mattjakeman.ExtensionManager"
)

# Generic installer: sw_install "Name" "dnf packages" "flatpak app id"
sw_install() {
  local name=$1 pkgs=$2 fp=$3
  if [[ -n $pkgs ]]; then
    # shellcheck disable=SC2086
    if run dnf -y install $pkgs; then ok "$name installed (dnf)."; return 0; fi
    [[ -n $fp ]] && warn "$name: dnf install failed - falling back to Flathub."
  fi
  if [[ -n $fp ]]; then
    flathub_enabled || step_flathub || return 1
    if run flatpak install -y --noninteractive flathub "$fp"; then ok "$name installed (Flathub)."; return 0; fi
  fi
  return 1
}

# Install one app from the SOFTWARE table, running its hooks if it has any.
sw_app() {
  local key=$1 name=$2 pkgs=$3 fp=$4
  if declare -F "sw_pre_$key" >/dev/null && ! "sw_pre_$key"; then pkgs=""; fi
  if sw_install "$name" "$pkgs" "$fp"; then
    if declare -F "sw_post_$key" >/dev/null; then "sw_post_$key"; fi
    return 0
  fi
  if declare -F "sw_fallback_$key" >/dev/null && "sw_fallback_$key"; then return 0; fi
  err "$name could not be installed."; return 1
}

# Is an app installed?  Prints a status token (see render_status).
sw_status() {
  local key=$1 pkgs=$2 fp=$3
  # shellcheck disable=SC2086
  if [[ -n $pkgs ]] && have $pkgs; then echo ok; return; fi
  if [[ -n $fp ]] && flatpak info "$fp" >/dev/null 2>&1; then echo ok; return; fi
  if declare -F "sw_status_$key" >/dev/null; then "sw_status_$key"; fi
}

# ----- Brave Origin (stable), from Brave's own dnf repository -----------------
BRAVE_REPO_URL="https://brave-browser-rpm-release.s3.brave.com/brave-browser.repo"

sw_pre_brave() {
  grep -rqs 'brave-browser-rpm-release' /etc/yum.repos.d/ && return 0
  info "Adding Brave's stable (release) repository…"
  # dnf5 syntax first; the older --add-repo form is kept as a fallback
  run dnf config-manager addrepo --overwrite --from-repofile="$BRAVE_REPO_URL" \
    || run dnf config-manager --add-repo "$BRAVE_REPO_URL" \
    || { err "Could not add the Brave repo."; return 1; }
}

# Install Chrome Web Store extensions into Brave via managed policy.
# Brave fetches and auto-updates them from the Web Store on next start.
BRAVE_POLICY_FILE="/etc/brave/policies/managed/postinstall-extensions.json"
BRAVE_EXTENSIONS=(
  "nngceckbapebfimnlniiiahkandclblb"   # Bitwarden Password Manager
)
sw_post_brave() {
  local mode="normal_installed" id first=1
  echo
  echo "    Adding the Bitwarden extension via Brave's managed policy."
  echo "    Brave will show 'Managed by your organisation' and the extension"
  echo "    can't be removed from inside Brave (edit/delete $BRAVE_POLICY_FILE instead)."
  if opt OPT_BRAVE_LOCK_BITWARDEN "Lock Bitwarden fully (can't even be switched off)"; then mode="force_installed"; fi
  install -d -m 0755 "$(dirname "$BRAVE_POLICY_FILE")"
  {
    echo '{'
    echo '  "ExtensionSettings": {'
    for id in "${BRAVE_EXTENSIONS[@]}"; do
      [[ $first -eq 1 ]] || echo ','
      first=0
      printf '    "%s": {\n      "installation_mode": "%s",\n      "update_url": "https://clients2.google.com/service/update2/crx"\n    }' "$id" "$mode"
    done
    echo
    echo '  }'
    echo '}'
  } >"$BRAVE_POLICY_FILE"
  chmod 0644 "$BRAVE_POLICY_FILE"
  if command -v python3 >/dev/null && ! python3 -m json.tool "$BRAVE_POLICY_FILE" >/dev/null 2>&1; then
    err "Policy file is not valid JSON - removing it."; rm -f "$BRAVE_POLICY_FILE"; return 1
  fi
  ok "Bitwarden extension queued ($mode) - it appears next time Brave starts (check brave://policy)."
}

sw_fallback_brave() {
  warn "Brave Origin could not be installed from Brave's repo."
  echo "    The only Flathub fallback is regular Brave (com.brave.Browser), NOT Brave Origin."
  opt OPT_BRAVE_FLATHUB_FALLBACK "Install regular Brave from Flathub instead" || return 1
  sw_install "Brave (Flathub)" "" com.brave.Browser || return 1
  warn "The Flatpak can't read host policies - add the Bitwarden extension from the Web Store yourself."
}

sw_status_brave() {
  flatpak info com.brave.Browser >/dev/null 2>&1 && echo "warn:regular Brave (Flathub), not Origin"
}

# ----- VLC ---------------------------------------------------------------------
sw_pre_vlc() {
  # VLC is in Fedora's own repo; HEVC etc. come from the codecs step (3)
  rpmfusion_enabled || warn "RPM Fusion not enabled - some formats won't play until you run step 3."
  return 0
}

# ----- Bitwarden: Flathub-only. The official .rpm has no repo, so dnf never
#       updates it, whereas the Flathub build updates with 'flatpak update'.

# ----- Mullvad VPN (no official Flatpak, so no fallback) ------------------------
sw_pre_mullvad() {
  [[ -f /etc/yum.repos.d/mullvad.repo ]] && return 0
  info "Adding Mullvad repository…"
  # dnf5 syntax first; the older --add-repo form is kept as a fallback
  run dnf config-manager addrepo --from-repofile=https://repository.mullvad.net/rpm/stable/mullvad.repo \
    || run dnf config-manager --add-repo https://repository.mullvad.net/rpm/stable/mullvad.repo \
    || { err "Could not add the Mullvad repo."; return 1; }
}

# ----- VS Code -----------------------------------------------------------------
sw_pre_vscode() {
  if [[ ! -f /etc/yum.repos.d/vscode.repo ]]; then
    info "Adding Microsoft VS Code repository…"
    run rpm --import https://packages.microsoft.com/keys/microsoft.asc || warn "Could not import Microsoft key"
    cat >/etc/yum.repos.d/vscode.repo <<'REPO'
[code]
name=Visual Studio Code
baseurl=https://packages.microsoft.com/yumrepos/vscode
enabled=1
autorefresh=1
type=rpm-md
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
REPO
  fi
  # Fedora 45 ships OpenSSL 4; VS Code's extension signer still needs libssl.so.3
  run dnf -y install openssl3-libs || warn "openssl3-libs not installed - extension installs may fail"
  return 0
}

# ----- Claude Code -------------------------------------------------------------
sw_pre_claude_code() {
  local fpr_ok="31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE" tmp got
  [[ -f /etc/yum.repos.d/claude-code.repo ]] && return 0
  info "Adding Anthropic's Claude Code repository…"
  tmp="$(mktemp -d)"
  if curl -fsSL -o "$tmp/claude-code.asc" https://downloads.claude.ai/keys/claude-code.asc; then
    got="$(gpg --show-keys --with-colons "$tmp/claude-code.asc" 2>/dev/null | awk -F: '/^fpr/{print $10; exit}')"
    if [[ $got == "$fpr_ok" ]]; then
      run rpm --import "$tmp/claude-code.asc"
      cat >/etc/yum.repos.d/claude-code.repo <<'REPO'
[claude-code]
name=Claude Code
baseurl=https://downloads.claude.ai/claude-code/rpm/stable
enabled=1
gpgcheck=1
repo_gpgcheck=0
gpgkey=https://downloads.claude.ai/keys/claude-code.asc
REPO
    else
      err "Claude Code signing key fingerprint mismatch (got '${got:-none}') - repo NOT added."
    fi
  else
    warn "Could not download the Claude Code signing key."
  fi
  rm -rf "$tmp"
  [[ -f /etc/yum.repos.d/claude-code.repo ]]
}

sw_fallback_claude_code() {
  # No Flatpak exists; the fallback is Anthropic's native per-user installer
  warn "dnf install failed - falling back to Anthropic's native installer (per-user, ~/.local/bin)."
  local u; u="$(desktop_user)" || { err "No desktop user (run via sudo) - can't do the per-user install."; return 1; }
  if as_user bash -c 'set -o pipefail; curl -fsSL https://claude.ai/install.sh | bash' 2>&1 | tee -a "$LOG"; [[ ${PIPESTATUS[0]} -eq 0 ]]; then
    ok "Claude Code installed for $u in ~/.local/bin (make sure that's on your PATH)."; return 0
  fi
  return 1
}

sw_status_claude_code() {
  local home; home="$(user_home)" || return 0
  [[ -x $home/.local/bin/claude ]] && echo ok
}

sw_run() {
  local i=$1 key label pkgs fp rc
  IFS='|' read -r key label pkgs fp <<<"${SOFTWARE[$i]}"
  echo; echo "${C_B}── Software: $label ──${C_0}"
  sw_app "$key" "$label" "$pkgs" "$fp"; rc=$?
  case $rc in
    0) SW_RESULT[$key]="${C_G}done${C_0}" ;;
    2) SW_RESULT[$key]="${C_Y}skipped${C_0}" ;;
    *) SW_RESULT[$key]="${C_R}FAILED${C_0}" ;;
  esac
}

software_menu() {
  local choice tok i key label pkgs fp st
  while true; do
    echo
    echo "${C_B}Software${C_0}   (dnf first, Flathub fallback)"
    echo "────────────────────────────────────────────────────────────"
    for i in "${!SOFTWARE[@]}"; do
      IFS='|' read -r key label pkgs fp <<<"${SOFTWARE[$i]}"
      st="${SW_RESULT[$key]:-}"
      [[ -n $st ]] || st="$(render_status "$(sw_status "$key" "$pkgs" "$fp")")"
      printf "  %2d) %-56s %s\n" $((i+1)) "$label" "$st"
    done
    echo "   A) All of the above"
    echo "   B) Back to main menu"
    echo
    read -rp "Select app(s), e.g. 1 3 6, or A: " choice || return 0
    for tok in ${choice//,/ }; do
      case ${tok^^} in
        A) for i in "${!SOFTWARE[@]}"; do sw_run "$i"; done ;;
        B|Q) return 0 ;;
        *) if [[ $tok =~ ^[0-9]+$ ]] && (( tok >= 1 && tok <= ${#SOFTWARE[@]} )); then
             sw_run $((tok-1))
           else
             warn "Unknown option: $tok"
           fi ;;
      esac
    done
  done
}

# =============================================================================
#  STATUS  - what's already on this machine, shown in the menus.
#  Each status_<step> prints one token:  ok | na:<why> | warn:<note> | (nothing)
# =============================================================================
render_status() {
  case ${1:-} in
    ok)     echo "${C_G}✔ installed${C_0}" ;;
    na:*)   echo "${C_D}n/a - ${1#na:}${C_0}" ;;
    warn:*) echo "${C_Y}${1#warn:}${C_0}" ;;
  esac
}

accent_installed() { extension_installed "$ACCENT_UUID"; }

status_update() {     # can't tell "fully updated" offline - only flag a pending kernel reboot
  local newest; newest="$(rpm -q kernel-core --last 2>/dev/null | head -1 | awk '{print $1}')"
  [[ -n $newest && $newest != "kernel-core-$(uname -r)" ]] && echo "warn:reboot to use the newest kernel"
}
status_rpmfusion() { rpmfusion_enabled && echo ok; }
status_codecs()    { have ffmpeg libdvdcss gstreamer1-plugin-openh264 && echo ok; }
status_nvidia() {
  if have akmod-nvidia || have akmod-nvidia-580xx || have akmod-nvidia-470xx; then
    if modinfo nvidia >/dev/null 2>&1; then echo ok; else echo "warn:installed, module not built yet"; fi
  elif ! gpu_lines | grep -qi nvidia; then
    echo "na:no NVIDIA GPU"
  fi
}
status_drivers() {
  if lspci -nn | grep -i 'network controller' | grep -qi broadcom && [[ ${OPT_BROADCOM_WL,,} == y* ]] && ! have akmod-wl; then
    echo "warn:broadcom-wl not installed"; return
  fi
  have linux-firmware alsa-sof-firmware amd-gpu-firmware intel-gpu-firmware nvidia-gpu-firmware && echo ok
}
status_devtools() {
  have gcc gcc-c++ make kernel-devel-matched || return
  if [[ -d /lib/modules/$(uname -r)/build ]]; then echo ok; else echo "warn:no headers for the running kernel"; fi
}
status_vmware() {
  [[ -f /usr/lib/vmware/modules/source/vmmon.tar ]] || { echo "na:VMware not installed"; return; }
  local k; k="$(uname -r)"
  if [[ -f /lib/modules/$k/misc/vmmon.ko && -f /lib/modules/$k/misc/vmnet.ko && -x $VMW_HOOK ]]; then echo ok
  else echo "warn:modules not built for this kernel"; fi
}
status_snapshots() {
  [[ $(findmnt -n -o FSTYPE /) == btrfs ]] || { echo "na:root is not Btrfs"; return; }
  [[ -f /etc/snapper/configs/root && -f /etc/dnf/libdnf5-plugins/actions.d/snapper.actions ]] && echo ok
}
status_flathub()  { flathub_enabled && echo ok; }
status_firmware() { :; }   # needs a network check - only known after running the step
status_gnome() {
  have gnome-tweaks || return
  local row id name uuid missing=0
  [[ ${OPT_ACCENT_COLOR,,} == y* ]] && ! accent_installed && missing=1
  for row in "${GNOME_EXTENSIONS[@]}"; do
    IFS='|' read -r id name <<<"$row"
    uuid="$(ego_uuid "$id")"
    [[ -n $uuid ]] && extension_installed "$uuid" || missing=$((missing+1))
  done
  if [[ $missing -gt 0 ]]; then echo "warn:$missing extension(s) not installed"; else echo ok; fi
}
status_msfonts()  { [[ -f /usr/share/fonts/msttcore/arial.ttf ]] && echo ok; }
status_openssl3() { have openssl3-libs && echo ok; }
status_gaming() {
  have steam || return
  # shellcheck disable=SC2086
  have $GAMING_PACKAGES || { echo "warn:some gaming extras missing"; return; }
  if [[ ${OPT_PROTON_GE,,} == y* ]] && ! proton_ge_installed; then echo "warn:Proton-GE not installed"; return; fi
  echo ok
}

# ---------- menu -------------------------------------------------------------
STEPS=(update rpmfusion codecs nvidia drivers devtools vmware snapshots flathub firmware gnome msfonts openssl3 gaming)
LABELS=(
  "Update system (dnf upgrade --refresh)"
  "Enable RPM Fusion (free, nonfree, free-tainted)"
  "Media codecs (ffmpeg, GStreamer, VA-API, DVD, rar/7z)"
  "NVIDIA proprietary driver (akmod, choose branch)"
  "Other drivers & firmware (Broadcom Wi-Fi, GPU/audio fw)"
  "Build tools (GCC, make, kernel-devel/headers)"
  "VMware Workstation modules (build, sign, auto-rebuild)"
  "Btrfs snapshots (snapper, snapshot on every dnf run)"
  "Flathub (full catalogue + Fedora third-party repos)"
  "Firmware updates (fwupd / LVFS)"
  "GNOME tweaks (buttons, tray, accent colour, Ext. Mgr)"
  "Microsoft core fonts (Arial, Times, Verdana...)"
  "OpenSSL 3 compat libs (VS Code & vendor apps)"
  "Gaming (Steam, Proton-GE, Lutris, GameMode, MangoHud)"
)
# Order used by 'A': snapshot first so there's a rollback point, firmware near the end
ALL_ORDER=(snapshots update rpmfusion codecs nvidia drivers devtools vmware flathub gnome msfonts openssl3 gaming firmware)

run_step() {
  local i=$1 name=${STEPS[$1]}
  echo; echo "${C_B}── Step $((i+1)): ${LABELS[$i]} ──${C_0}"
  "step_$name"; local rc=$?
  case $rc in
    0) RESULT[$name]="${C_G}done${C_0}" ;;
    2) RESULT[$name]="${C_Y}skipped${C_0}" ;;
    *) RESULT[$name]="${C_R}FAILED${C_0}" ;;
  esac
}

show_menu() {
  local sb="off" i name st; secure_boot_enabled && sb="ON"
  echo
  echo "${C_B}Fedora ${VERSION_ID} post-install${C_0}   kernel $(uname -r)   Secure Boot: $sb"
  echo "────────────────────────────────────────────────────────────"
  for i in "${!STEPS[@]}"; do
    name=${STEPS[$i]}
    [[ $i -eq 7 ]] && echo "  ── Extras ──"
    st="${RESULT[$name]:-}"                      # this run's result wins; otherwise detect
    [[ -n $st ]] || st="$(render_status "$("status_$name")")"
    printf "  %2d) %-56s %s\n" $((i+1)) "${LABELS[$i]}" "$st"
  done
  echo "   A) All of the above (takes a snapshot first)"
  echo "   S) Software…  (Brave, VLC, VS Code, Claude Code…)"
  echo "   Q) Quit"
  echo
}

handle_choice() {
  local tok
  for tok in ${1//,/ }; do
    case ${tok^^} in
      A) local n i
         for n in "${ALL_ORDER[@]}"; do
           for i in "${!STEPS[@]}"; do [[ ${STEPS[$i]} == "$n" ]] && run_step "$i"; done
         done ;;
      S) software_menu ;;
      Q) return 1 ;;
      *) if [[ $tok =~ ^[0-9]+$ ]] && (( tok >= 1 && tok <= ${#STEPS[@]} )); then
           run_step $((tok-1))
         else
           warn "Unknown option: $tok"
         fi ;;
    esac
  done
}

finish() {
  echo
  echo "${C_B}Summary${C_0}"
  for i in "${!STEPS[@]}"; do
    [[ -n ${RESULT[${STEPS[$i]}]:-} ]] && printf "  %-58s %s\n" "${LABELS[$i]}" "${RESULT[${STEPS[$i]}]}"
  done
  local key label rest
  for i in "${!SOFTWARE[@]}"; do
    IFS='|' read -r key label rest <<<"${SOFTWARE[$i]}"
    [[ -n ${SW_RESULT[$key]:-} ]] && printf "  %-58s %s\n" "$label" "${SW_RESULT[$key]}"
  done
  echo "  Log: $LOG"
  if [[ $MOK_PENDING -eq 1 ]]; then
    echo
    echo "${C_Y}${C_B}  On reboot you'll see a blue MOK Management screen:${C_0}"
    echo "    Enroll MOK → Continue → Yes → type the password you set → Reboot."
    echo "    If you miss it (it times out), run this script's step 4, 5 or 7 again."
  fi
  if [[ $NEED_REBOOT -eq 1 ]]; then
    if opt OPT_REBOOT_WHEN_DONE "Reboot now"; then systemctl reboot
    else warn "A reboot is needed to finish - reboot when convenient."; fi
  fi
}

# Non-interactive: arguments on the command line
if [[ $# -gt 0 ]]; then
  handle_choice "$*"; finish; exit 0
fi

while true; do
  show_menu
  read -rp "Select step(s), e.g. 1 3 5, or A: " choice || break
  handle_choice "$choice" || break
done
finish
