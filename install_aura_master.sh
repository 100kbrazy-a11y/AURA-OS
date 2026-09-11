#!/usr/bin/env bash
#===============================================================================
#
#   █████╗ ██╗   ██╗██████╗  █████╗      ██████╗ ███████╗
#  ██╔══██╗██║   ██║██╔══██╗██╔══██╗    ██╔══██╗██╔════╝
#  ███████║██║   ██║██████╔╝███████║    ██║  ██║███████╗
#  ██╔══██║██║   ██║██╔══██╗██╔══██║    ██║  ██║╚════██║
#  ██║  ██║╚██████╔╝██║  ██║██║  ██║    ██████╔╝███████║
#  ╚═╝  ╚═╝ ╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═╝    ╚═════╝ ╚══════╝
#
#  AURA OS — Master Installer  (Linux Mint / Debian -> dedicated kiosk shell)
#  Python + PyQt5 + Qt Quick GPU shaders · PS3 wave · glass refraction · TV UX
#
#  Usage:
#    sudo bash install_aura_master.sh                # full install + test run
#    sudo bash install_aura_master.sh --no-test      # install, skip test run
#    sudo bash install_aura_master.sh --uninstall    # remove Aura OS cleanly
#
#  Env overrides:
#    AURA_SKIP_APT=1     never touch apt (offline / pre-provisioned hosts)
#
#===============================================================================

set -o pipefail
AURA_VERSION="2.0.0"
AURA_DIR="${AURA_DIR:-/opt/aura-os-native}"        # override for custom prefix
XS_DIR="${XS_DIR:-/usr/share/xsessions}"            # override for testing
APP_DIR="${APP_DIR:-/usr/share/applications}"       # override for testing
LOG_FILE="${AURA_LOG:-/var/log/aura-os-install.log}"
NO_TEST=0
SELFTEST_OK=0

C_RED=$'\033[1;31m'; C_GRN=$'\033[1;32m'; C_YLW=$'\033[1;33m'
C_CYN=$'\033[1;36m'; C_DIM=$'\033[2m';   C_BLD=$'\033[1m';  C_OFF=$'\033[0m'

# --------------------------------------------------------------------------
# pretty output helpers
# --------------------------------------------------------------------------
banner() {
    printf "%b" "$C_CYN$C_BLD"
    cat <<'BANNER_EOF'
   █████╗ ██╗   ██╗██████╗  █████╗      ██████╗ ███████╗
  ██╔══██╗██║   ██║██╔══██╗██╔══██╗    ██╔══██╗██╔════╝
  ███████║██║   ██║██████╔╝███████║    ██║  ██║███████╗
  ██╔══██║██║   ██║██╔══██╗██╔══██║    ██║  ██║╚════██║
  ██║  ██║╚██████╔╝██║  ██║██║  ██║    ██████╔╝███████║
  ╚═╝  ╚═╝ ╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═╝    ╚═════╝ ╚══════╝
BANNER_EOF
    printf "%b\n" "$C_OFF      Native Kiosk Shell  ·  v$AURA_VERSION  ·  PyQt5 + Qt Quick"
}

info() { printf "  %b\n" "$C_BLD$1$C_OFF"; }
ok()   { printf "  %b✔ %b\n" "$C_GRN" "$1$C_OFF"; }
warn() { printf "  %b⚠ %b\n" "$C_YLW" "$1$C_OFF"; }
die()  { printf "  %b✖ ERROR: %b\n" "$C_RED" "$1$C_OFF" >&2; exit 1; }

SPIN_PID=0; SPIN_MSG=""
spinner_start() {
    SPIN_MSG="$1"
    ( while :; do
        for c in '|' '/' '-' '\'; do
            printf "\r  %b%s %b" "$C_CYN" "$c" "$SPIN_MSG$C_OFF"
            sleep 0.08
        done
      done ) & SPIN_PID=$!
}
spinner_stop() {
    local rc="$1"
    kill "$SPIN_PID" 2>/dev/null; wait "$SPIN_PID" 2>/dev/null
    printf "\r  \r"
    if [ "$rc" -eq 0 ]; then
        ok "$SPIN_MSG"
    else
        printf "\n"
        warn "Step failed: $SPIN_MSG — last log lines:"
        tail -n 30 "$LOG_FILE" 2>/dev/null | sed 's/^/    /'
    fi
    return "$rc"
}
run_step() {
    local msg="$1"; shift
    : >>"$LOG_FILE"
    spinner_start "$msg"
    "$@" >>"$LOG_FILE" 2>&1
    spinner_stop $?
}
step_or_die() {
    run_step "$@" || die "Installation aborted while: $SPIN_MSG"
}

# --------------------------------------------------------------------------
# argument handling + privilege / environment preflight
# --------------------------------------------------------------------------
case "${1:-}" in
    --uninstall) DO_UNINSTALL=1 ;;
    --no-test)   NO_TEST=1 ;;
    "") ;;
    *) die "Unknown option '$1'. Use --uninstall or --no-test." ;;
esac

if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi

if [ "${1:-}" = "--uninstall" ]; then
    banner
    if [ "$(id -u)" -ne 0 ]; then
        command -v sudo >/dev/null 2>&1 || die "Please run as root."
        exec sudo -E bash "$0" --uninstall
    fi
    TARGET_USER="${SUDO_USER:-}"
    [ -z "$TARGET_USER" ] && TARGET_USER="$(logname 2>/dev/null || true)"
    AS_FILE="/var/lib/AccountsService/users/${TARGET_USER:-_none_}"
    info "Stopping Aura OS processes..."
    pkill -f "$AURA_DIR/main.py" 2>/dev/null
    pkill -f "$AURA_DIR/aura-session.sh" 2>/dev/null
    pkill -x xbindkeys 2>/dev/null
    info "Removing files..."
    rm -rf "$AURA_DIR"
    rm -f  "$XS_DIR/aura-os.desktop" "$APP_DIR/aura-os-preview.desktop"
    if [ -f "$AS_FILE" ]; then
        sed -i -e '/^Session=aura-os$/d' -e '/^XSession=aura-os$/d' "$AS_FILE"
        ok "Default session unselected in AccountsService."
    fi
    ok "Aura OS removed. (Installed apt packages were left in place.)"
    exit 0
fi

# AURA_NO_ROOT=1 is a container/CI test hook: run the steps without sudo.
if [ "$(id -u)" -ne 0 ] && [ "${AURA_NO_ROOT:-0}" != "1" ]; then
    command -v sudo >/dev/null 2>&1 || die "Please run as root."
    exec sudo -E env AURA_SKIP_APT="${AURA_SKIP_APT:-0}" bash "$0" "$@"
fi

banner

# --------------------------------------------------------------------------
# resolve the *human* user who will own the session
# --------------------------------------------------------------------------
TARGET_USER="${AURA_USER:-${SUDO_USER:-}}"
if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" = "root" ]; then
    TARGET_USER="$(logname 2>/dev/null || true)"
fi
if [ -z "$TARGET_USER" ] && [ -n "${XDG_RUNTIME_DIR:-}" ]; then
    TARGET_USER="$(stat -c %U "$XDG_RUNTIME_DIR" 2>/dev/null || true)"
fi
if [ -z "$TARGET_USER" ] && [ -d /run/user ]; then
    for d in /run/user/1*; do
        if [ -d "$d" ]; then TARGET_USER="$(stat -c %U "$d" 2>/dev/null)"; break; fi
    done
fi
if [ -z "$TARGET_USER" ]; then TARGET_USER="root"; fi
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[ -z "$TARGET_HOME" ] && TARGET_HOME="/root"
TARGET_UID="$(id -u "$TARGET_USER" 2>/dev/null || echo 0)"

info "Target user   : $TARGET_USER ($TARGET_HOME)"
info "Install prefix: $AURA_DIR"
printf "\n"

# --------------------------------------------------------------------------
# [1/6] dependency check & install
# --------------------------------------------------------------------------
info "[1/6] Checking dependencies..."

PKGS=(python3 python3-pyqt5 qml-module-qtquick2 qml-module-qtquick-window2
      qml-module-qtgraphicaleffects libqt5svg5
      wmctrl xdotool playerctl xbindkeys x11-xserver-utils
      network-manager bluez)

NEED=()
for p in "${PKGS[@]}"; do
    dpkg -s "$p" >/dev/null 2>&1 || NEED+=("$p")
done

if [ "${#NEED[@]}" -gt 0 ]; then
    if [ "${AURA_SKIP_APT:-0}" = "1" ]; then
        warn "AURA_SKIP_APT=1 → skipping apt. Missing: ${NEED[*]}"
    else
        command -v apt-get >/dev/null 2>&1 \
            || die "apt-get not found. This installer targets Debian/Mint."
        export DEBIAN_FRONTEND=noninteractive
        run_step "Refreshing package index" apt-get update \
            || warn "apt-get update failed — trying to continue with cached index."
        step_or_die "Installing ${#NEED[@]} packages (PyQt5 · QML runtime · TV tools)" \
            apt-get -y install "${NEED[@]}"
    fi
else
    ok "All apt packages already present."
fi

for b in python3 wmctrl xdotool playerctl xbindkeys xrandr xset; do
    command -v "$b" >/dev/null 2>&1 \
        || die "Required binary '$b' missing even after install — aborting."
done

# PyQt5 QtQuick bindings (Debian may split them into python3-pyqt5.qtquick)
if ! python3 -c "import PyQt5.QtCore, PyQt5.QtQml, PyQt5.QtQuick, PyQt5.QtGui" >/dev/null 2>&1; then
    if [ "${AURA_SKIP_APT:-0}" != "1" ]; then
        run_step "Installing python3-pyqt5.qtquick (split package)" \
            apt-get -y install python3-pyqt5.qtquick
    fi
    python3 -c "import PyQt5.QtQuick" >/dev/null 2>&1 \
        || die "PyQt5 QtQuick bindings are unavailable on this system."
fi

QMLROOT=""
for c in /usr/lib/*/qt5/qml /usr/lib/qt5/qml /usr/lib64/qt5/qml; do
    if [ -d "$c" ]; then QMLROOT="$c"; break; fi
done
if [ -z "$QMLROOT" ]; then
    PYQML="$(python3 -c "import os,PyQt5; print(os.path.join(os.path.dirname(PyQt5.__file__),'Qt5','qml'))" 2>/dev/null || true)"
    [ -n "$PYQML" ] && [ -d "$PYQML" ] && QMLROOT="$PYQML"
fi
[ -n "$QMLROOT" ] || die "Qt5 QML module directory not found."
[ -f "$QMLROOT/QtQuick.2/qmldir" ] || die "QML module QtQuick.2 is missing."
[ -f "$QMLROOT/QtGraphicalEffects/qmldir" ] || die "QML module QtGraphicalEffects is missing (install qml-module-qtgraphicaleffects)."
ok "Dependency check passed."

# --------------------------------------------------------------------------
# [2/6] build project structure
# --------------------------------------------------------------------------
info "[2/6] Building $AURA_DIR ..."
mkdir -p "$AURA_DIR" || die "Cannot create $AURA_DIR"

cat > "$AURA_DIR/main.py" <<'AURA_MAIN_PY_EOF'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
AURA OS - Native Kiosk Shell (backend) v2 "Glass"
=================================================
Performance-first rendering engine: Python + PyQt5 (Qt Quick / QML, GPU shaders).

v2 additions over v1:
  * Window-mode state machine: every foreign window gets a mode
    (full / float(PiP) / left / right) with geometry enforcement.
  * Picture-in-Picture: float mode pins an app borderless, top-right,
    always-on-top; promote to fullscreen / fill left / fill right / close.
  * Split behaviour: filling one half moves any fullscreen app to the
    opposite half automatically.
  * Double-press Home (Super) within 450ms -> closes PiP + opens the
    Control Center even while a game is running; single press backgrounds
    (unmaps) running apps and returns to the shell.
  * All foreign windows are stripped of decorations via _MOTIF_WM_HINTS
    (works with muffin/marco/openbox) - the kiosk itself runs without a WM,
    so nothing is ever decorated.
  * Full Settings backend: display modes (xrandr), sinks (pactl), Wi-Fi
    (nmcli), Bluetooth (bluetoothctl), night mode, blank timer, cursor
    size/delay, wave/glass tuning - all persisted to settings.json.
  * Dim state is derived from live window state (bindings never get stuck).
"""

import os
import sys
import re
import json
import time
import glob
import signal
import shutil
import subprocess
import threading
import configparser
from urllib import request as urlrequest
from urllib.parse import quote

SELFTEST = "--selftest" in sys.argv
if SELFTEST:
    os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
    os.environ.setdefault("QT_QUICK_BACKEND", "software")

from PyQt5.QtCore import (QObject, QTimer, QUrl, Qt, QEvent, QSize,
                          pyqtProperty, pyqtSignal, pyqtSlot)
from PyQt5.QtGui import (QGuiApplication, QIcon, QPixmap, QPainter, QColor,
                         QCursor, QFont)
from PyQt5.QtQml import QQmlApplicationEngine
from PyQt5.QtQuick import QQuickImageProvider, QSGRendererInterface

APP_NAME = "Aura OS"
APP_VERSION = "2.0.0"
AURA_DIR = os.path.dirname(os.path.abspath(__file__))
DEFAULT_ACCENT = "#e8434f"
CONFIG_DIR = os.path.expanduser("~/.config/aura-os")
CACHE_DIR = os.path.expanduser("~/.cache/aura-os")
SETTINGS_FILE = os.path.join(CONFIG_DIR, "settings.json")
LEGACY_THEME_FILE = os.path.join(CONFIG_DIR, "theme.json")
WEATHER_FILE = os.path.join(CACHE_DIR, "weather.json")
RUNTIME_DIR = os.path.join(os.environ.get("XDG_RUNTIME_DIR",
                                          "/run/user/%d" % os.getuid()), "aura-os")
FIFO_PATH = os.path.join(RUNTIME_DIR, "home.fifo")

_selftest_mode = SELFTEST

DEFAULT_SETTINGS = {
    "accent": DEFAULT_ACCENT,
    "waveIntensity": 1.0,
    "waveSpeed": 1.0,
    "glassRefr": 0.016,
    "glassTint": 0.16,
    "iconScale": 1.0,
    "clock24": True,
    "showSeconds": False,
    "city": "",
    "blankMin": 0,
    "nightMode": False,
    "cursorAutohide": True,
    "cursorDelay": 5,
    "cursorSize": 24,
}


def log(msg):
    sys.stdout.write("[aura %s] %s\n" % (time.strftime("%H:%M:%S"), str(msg)))
    sys.stdout.flush()


# ---------------------------------------------------------------------------
# Application scraper + junk filter
# ---------------------------------------------------------------------------

JUNK_NAMES = {
    "about", "about me", "about my system", "accessibility", "universal access",
    "background", "backgrounds", "wallpaper", "color", "colors", "colour",
    "colours", "virtual keyboard", "onboard", "onboard settings", "screensaver",
    "screen locker", "lock screen", "extensions", "extension manager",
    "gnome extensions", "input method", "input method selector",
    "input method panel", "keyboard shortcuts", "default applications",
    "removable media", "printing options", "region & language",
    "date & time", "power statistics", "system monitor applet",
}

KEEP_NAMES = {
    "settings", "system settings", "control center", "all settings",
    "settings manager",
}

# Desktop-id level junk (granular system applets / settings panels)
JUNK_ID_RE = re.compile(
    r"(-panel\.desktop$"
    r"|^cinnamon-settings-"
    r"|^kcm_"
    r"|^xfce4-[a-z0-9-]+-settings\.desktop$"
    r"|^org\.gnome\.Settings\.data"
    r"|screensaver"
    r"|onboard)", re.IGNORECASE)

# Exec lines invoking a specific settings module = granular panel, not the app
SETTINGS_EXEC_RE = re.compile(
    r"^(gnome-control-center|cinnamon-settings|xfce4-settings|systemsettings\d*"
    r"|kcmshell\d*)\s+\S+")


def _parse_lang():
    loc = os.environ.get("LC_MESSAGES", os.environ.get("LANG", "")) or ""
    loc = loc.split(".", 1)[0]
    parts = [p for p in loc.replace("@", ".").split(".") if p]
    out = []
    if loc:
        out.append(loc)
        if "_" in loc:
            out.append(loc.split("_")[0])
    return out


def _clean_exec(exec_line):
    if not exec_line:
        return ""
    line = re.sub(r"%[a-zA-Z]", "", exec_line)
    return line.strip()


def _to_bool(val):
    return str(val).strip().lower() in ("1", "true", "yes", "on")


class AppScanner(object):
    """Parses .desktop entries and builds TV rows (categories)."""

    SCAN_DIRS = [
        "/usr/share/applications",
        "/usr/local/share/applications",
        "/var/lib/flatpak/exports/share/applications",
        os.path.expanduser("~/.local/share/applications"),
        os.path.expanduser("~/.local/share/flatpak/exports/share/applications"),
    ]

    CAT_MAP = {
        "Game": "Games", "Games": "Games",
        "AudioVideo": "Media", "Audio": "Media", "Video": "Media",
        "Music": "Media", "Player": "Media",
        "Network": "Internet", "WebBrowser": "Internet", "Email": "Internet",
        "InstantMessaging": "Internet", "Chat": "Internet", "P2P": "Internet",
        "Telephony": "Internet", "News": "Internet",
        "Graphics": "Graphics", "Photography": "Graphics",
        "2DGraphics": "Graphics", "3DGraphics": "Graphics",
        "RasterGraphics": "Graphics", "VectorGraphics": "Graphics",
        "Scanning": "Graphics", "Scanner": "Graphics",
        "Office": "Office", "WordProcessor": "Office", "Spreadsheet": "Office",
        "Presentation": "Office", "Database": "Office", "Finance": "Office",
        "Calendar": "Office", "ProjectManagement": "Office",
        "Development": "Development", "IDE": "Development",
        "Programming": "Development", "WebDevelopment": "Development",
        "RevisionControl": "Development", "Debugger": "Development",
        "Science": "Education", "Education": "Education", "Math": "Education",
        "Teaching": "Education",
        "Utility": "Utilities", "Accessories": "Utilities",
        "Archiving": "Utilities", "FileTools": "Utilities",
        "TextEditor": "Utilities", "FileManager": "Utilities",
        "TerminalEmulator": "Utilities", "Compression": "Utilities",
        "System": "System", "Settings": "System", "PackageManager": "System",
        "Monitor": "System", "Security": "System", "HardwareSettings": "System",
    }

    ROW_ORDER = ["Media", "Internet", "Games", "Graphics", "Office",
                 "Education", "Development", "Utilities", "System", "Other"]

    def __init__(self):
        self.apps_by_id = {}      # desktop id -> entry dict
        self.icons_by_key = {}    # provider key -> QIcon
        self.rows = []
        self.langs = _parse_lang()

    # -- junk filter ----------------------------------------------------
    def _is_junk(self, path, did, name, entry):
        if "/screensavers/" in path or "/Screensavers/" in path:
            return True
        if JUNK_ID_RE.search(did):
            return True
        if name.lower() in JUNK_NAMES and name.lower() not in KEEP_NAMES:
            return True
        if SETTINGS_EXEC_RE.match(_clean_exec(entry.get("exec", ""))):
            return True
        cats = entry.get("categories", [])
        if "X-GNOME-Settings-Panel" in cats and name.lower() not in KEEP_NAMES:
            return True
        return False

    def _display_name(self, cp, did):
        for lang in self.langs:
            try:
                v = cp.get("Desktop Entry", "Name[%s]" % lang, fallback=None)
                if v:
                    return str(v).strip()
            except Exception:
                pass
        try:
            v = cp.get("Desktop Entry", "Name", fallback=None)
            if v:
                return str(v).strip()
        except Exception:
            pass
        return did.replace(".desktop", "").replace("-", " ").strip().title()

    def scan(self):
        candidates = {}  # did -> path
        for d in self.SCAN_DIRS:
            if not os.path.isdir(d):
                continue
            for path in glob.glob(os.path.join(d, "**", "*.desktop"),
                                  recursive=True):
                did = os.path.basename(path)
                candidates[did] = path  # later dirs (user) override system
        key_n = 0
        for did, path in sorted(candidates.items()):
            cp = configparser.RawConfigParser(strict=False)
            try:
                with open(path, "r", encoding="utf-8", errors="ignore") as fh:
                    cp.read_file(fh)
            except Exception:
                continue
            if not cp.has_section("Desktop Entry"):
                continue
            g = lambda k, dflt=None: cp.get("Desktop Entry", k, fallback=dflt)
            name = self._display_name(cp, did)
            etype = (g("Type") or "Application").strip()
            if etype != "Application":
                continue
            if _to_bool(g("NoDisplay", "false")) or _to_bool(g("Hidden", "false")):
                continue
            if _to_bool(g("Terminal", "false")):
                continue
            exec_line = _clean_exec(g("Exec") or "")
            if not exec_line:
                continue
            tryex = (g("TryExec") or "").strip()
            if tryex and not shutil.which(tryex):
                continue
            cats = [c for c in (g("Categories") or "").split(";") if c]
            entry = {"id": did, "name": name, "exec": exec_line,
                     "icon": (g("Icon") or "").strip(), "categories": cats}
            if self._is_junk(path, did, name, entry):
                continue
            entry["_iconval"] = entry["icon"]
            self.apps_by_id[did] = entry
        # build rows + icon keys
        rowmap = {r: [] for r in self.ROW_ORDER}
        for did, entry in sorted(self.apps_by_id.items(),
                                 key=lambda kv: kv[1]["name"].lower()):
            row = "Other"
            for c in entry["categories"]:
                if c in self.CAT_MAP:
                    row = self.CAT_MAP[c]
                    break
            key_n += 1
            key = "a%d" % key_n
            entry["key"] = key
            self.icons_by_key[key] = self._resolve_icon(entry)
            rowmap.setdefault(row, []).append(
                {"id": entry["id"], "key": key, "name": entry["name"]})
        self.rows = [{"name": r, "apps": rowmap[r]}
                     for r in self.ROW_ORDER if rowmap[r]]
        log("App scan: %d applications, %d rows"
            % (len(self.apps_by_id), len(self.rows)))

    def _resolve_icon(self, entry):
        val = entry.get("_iconval", "")
        if val and os.path.isabs(val) and os.path.exists(val):
            ic = QIcon(val)
            if not ic.isNull():
                return ic
        if val:
            for cand in (val, val.lower()):
                ic = QIcon.fromTheme(cand)
                if ic and not ic.isNull():
                    return ic
            base = os.path.basename(_clean_exec(entry["exec"]).split()[-1]) \
                if entry["exec"] else ""
            if base:
                ic = QIcon.fromTheme(base)
                if ic and not ic.isNull():
                    return ic
        return QIcon()  # provider draws a letter tile


# ---------------------------------------------------------------------------
# Icon provider (QML: image://auraicons/<key>)
# ---------------------------------------------------------------------------

class IconProvider(QQuickImageProvider):
    def __init__(self, icons_by_key, bridge):
        super(IconProvider, self).__init__(QQuickImageProvider.Pixmap)
        self._icons = icons_by_key
        self._bridge = bridge
        self._tiles = {}

    def _letter_tile(self, letter):
        if letter in self._tiles:
            return self._tiles[letter]
        pm = QPixmap(256, 256)
        pm.fill(Qt.transparent)
        p = QPainter(pm)
        p.setRenderHint(QPainter.Antialiasing)
        base = QColor(self._bridge.accent if self._bridge else DEFAULT_ACCENT)
        base = base.darker(135)
        p.setBrush(base)
        p.setPen(Qt.NoPen)
        p.drawRoundedRect(8, 8, 240, 240, 48, 48)
        p.setPen(QColor(255, 255, 255, 225))
        f = QFont()
        f.setPixelSize(120)
        f.setBold(True)
        p.setFont(f)
        p.drawText(pm.rect(), Qt.AlignCenter, letter)
        p.end()
        self._tiles[letter] = pm
        return pm

    def requestPixmap(self, qid, *args):
        """PyQt5-safe: returns the (QPixmap, QSize) tuple PyQt5 expects."""
        size = args[0] if len(args) >= 1 and isinstance(args[0], QSize) else None
        requested = args[1] if len(args) >= 2 and isinstance(args[1], QSize) else None
        key = qid.split("?")[0]
        icon = self._icons.get(key)
        pm = None
        if icon is not None and not icon.isNull():
            want = requested if (requested and requested.width() > 0) \
                else None
            pm = icon.pixmap(want if want else QSize128)
            if pm.isNull():
                pm = None
        if pm is None:
            name = ""
            for row in (self._bridge.rows if self._bridge else []):
                for a in row["apps"]:
                    if a["key"] == key:
                        name = a["name"]
                        break
            letter = (name[:1] or "?").upper()
            pm = self._letter_tile(letter)
        return pm, QSize(pm.width(), pm.height())


QSize128 = QSize(128, 128)

# ---------------------------------------------------------------------------
# AuraBridge - the IPC / system integration object exposed to QML
# ---------------------------------------------------------------------------

def _pid_alive(pid):
    if not pid:
        return False
    try:
        os.kill(int(pid), 0)
        return True
    except Exception:
        return False


def _pgid_of(pid):
    try:
        with open("/proc/%d/stat" % int(pid), "r") as f:
            rest = f.read().rsplit(") ", 1)[1]
        return int(rest.split()[2])  # state, ppid, pgrp
    except Exception:
        return 0


class AuraBridge(QObject):
    # ------------------------------------------------------------- signals
    accentChanged = pyqtSignal()
    uiChanged = pyqtSignal()
    rowsChanged = pyqtSignal()
    mediaChanged = pyqtSignal()
    mediaPosChanged = pyqtSignal()
    volumeChanged = pyqtSignal()
    brightnessChanged = pyqtSignal()
    weatherChanged = pyqtSignal()
    stateChanged = pyqtSignal()     # appCovered / pip / running ids
    netChanged = pyqtSignal()       # wifi + sinks + display modes
    btChanged = pyqtSignal()
    sysInfoChanged = pyqtSignal()
    swRenderChanged = pyqtSignal()
    homeRequested = pyqtSignal()    # raw FIFO press (from thread)
    homeTap = pyqtSignal()          # single press (debounced)
    homeDoubleTap = pyqtSignal()    # double press
    toast = pyqtSignal(str)
    toastArrived = pyqtSignal()

    MEDIA_FMT = ("{{playerName}}|{{title}}|{{artist}}|{{status}}"
                 "|{{mpris:length}}")

    DESKTOP_CLASSES = {
        "nemo-desktop", "xfdesktop", "plasmashell", "nautilus-desktop",
        "pcmanfm-desktop", "caja-desktop", "kdesktop", "folder-view",
    }

    def __init__(self, parent=None):
        super(AuraBridge, self).__init__(parent)
        self._scanner = AppScanner()
        self._scanner.scan()
        self._apps_by_id = self._scanner.apps_by_id

        self._set = dict(DEFAULT_SETTINGS)
        self._load_settings()
        self._accent = self._set.get("accent", DEFAULT_ACCENT)
        self._accent2 = self._derive_accent2(self._accent)

        self._media_active = False
        self._media_title = ""
        self._media_artist = ""
        self._media_status = ""
        self._media_pos = 0
        self._media_len = 0
        self._volume = 100
        self._muted = False
        self._brightness = 100
        self._weather = "Weather starting..."
        self._wx_wake = threading.Event()

        self._app_covered = False
        self._pip_active = False
        self._pip_name = ""
        self._running_ids = []
        self._last_aid = ""

        self._wins = {}       # wid -> {mode, app_id, name, pid, bg, ts}
        self._pending = []    # launches awaiting a window
        self._tracked = []
        self._own_win = None
        self._stop = False
        self._last_home = 0.0

        self._sinks = []
        self._cur_sink = ""
        self._res_list = []
        self._wifi_enabled = False
        self._wifi_list = []
        self._cur_ssid = ""
        self._bt_powered = False
        self._bt_devices = []
        self._sys_info = ""
        self._last_toast = ""
        self._net_lock = threading.Lock()

        self._have_playerctl = bool(shutil.which("playerctl"))
        self._have_pactl = bool(shutil.which("pactl"))
        self._have_amixer = bool(shutil.which("amixer"))
        self._have_xrandr = bool(shutil.which("xrandr"))
        self._have_xdotool = bool(shutil.which("xdotool")) and \
            bool(os.environ.get("DISPLAY"))
        self._have_wmctrl = bool(shutil.which("wmctrl"))
        self._have_nmcli = bool(shutil.which("nmcli"))
        self._have_bt = bool(shutil.which("bluetoothctl"))
        self._have_xrdb = bool(shutil.which("xrdb"))

        self._home_single_timer = QTimer(self)
        self._home_single_timer.setSingleShot(True)
        self._home_single_timer.setInterval(460)
        self._home_single_timer.timeout.connect(self.onHome)

    # ------------------------------------------------------------ helpers
    @staticmethod
    def _sh(args, timeout=5):
        try:
            out = subprocess.run(args, stdout=subprocess.PIPE,
                                 stderr=subprocess.DEVNULL, timeout=timeout)
            return out.stdout.decode("utf-8", "ignore")
        except Exception:
            return ""

    @staticmethod
    def _run_rc(args, timeout=20):
        try:
            p = subprocess.run(args, stdout=subprocess.DEVNULL,
                               stderr=subprocess.PIPE, timeout=timeout)
            return p.returncode, p.stderr.decode("utf-8", "ignore")
        except Exception as exc:
            return 1, str(exc).encode("utf-8", "ignore").decode("utf-8")

    def attach_window(self, win):
        self._own_win = win

    def _own_win_id(self):
        try:
            wid = int(self._own_win.winId())
            return wid if wid else 0
        except Exception:
            return 0

    # ------------------------------------------------------------ settings
    def _load_settings(self):
        data = {}
        try:
            with open(SETTINGS_FILE, "r") as f:
                d = json.load(f)
            if isinstance(d, dict):
                data.update(d)
        except Exception:
            try:
                with open(LEGACY_THEME_FILE, "r") as f:
                    d = json.load(f)
                if isinstance(d, dict):
                    data.update(d)
            except Exception:
                pass
        for k in DEFAULT_SETTINGS:
            if k in data and data[k] is not None:
                self._set[k] = data[k]
        # clamp
        self._set["waveIntensity"] = float(max(0.1, min(2.0,
            float(self._set["waveIntensity"]))))
        self._set["waveSpeed"] = float(max(0.1, min(3.0,
            float(self._set["waveSpeed"]))))
        self._set["glassRefr"] = float(max(0.0, min(0.05,
            float(self._set["glassRefr"]))))
        self._set["glassTint"] = float(max(0.0, min(0.6,
            float(self._set["glassTint"]))))
        self._set["iconScale"] = float(max(0.7, min(1.4,
            float(self._set["iconScale"]))))

    def _save_settings(self):
        try:
            os.makedirs(CONFIG_DIR, exist_ok=True)
            with open(SETTINGS_FILE, "w") as f:
                json.dump(self._set, f, indent=1)
        except Exception:
            pass

    def _put(self, key, value):
        if self._set.get(key) == value:
            return
        self._set[key] = value
        self._save_settings()
        self.uiChanged.emit()

    # ------------------------------------------------------------ startup
    def start(self):
        if _selftest_mode:
            return
        QTimer.singleShot(400, self._volume_refresh)
        QTimer.singleShot(700, self._brightness_refresh)
        self._apply_blank()
        self._apply_night()
        self._apply_cursor_size()

        if self._have_playerctl:
            t = QTimer(self)
            t.setInterval(2000)
            t.timeout.connect(self._media_poll)
            t.start()
            self._media_poll()
            self._pos_timer = QTimer(self)
            self._pos_timer.setInterval(1000)
            self._pos_timer.timeout.connect(self._media_pos_poll)
            self._pos_timer.start()

        if self._have_pactl or self._have_amixer:
            t = QTimer(self)
            t.setInterval(3000)
            t.timeout.connect(self._volume_refresh)
            t.start()

        if self._have_xrandr:
            t = QTimer(self)
            t.setInterval(5000)
            t.timeout.connect(self._brightness_refresh)
            t.start()

        if self._have_xdotool:
            t = QTimer(self)
            t.setInterval(1400)
            t.timeout.connect(self._watch_windows)
            t.start()

        self._ensure_xbindkeys()
        threading.Thread(target=self._weather_loop, daemon=True).start()
        threading.Thread(target=self._fifo_loop, daemon=True).start()

    def shutdown(self):
        self._stop = True
        self._kill_tracked()

    # ------------------------------------------------------------ properties
    def _get_accent(self):
        return self._accent

    accent = pyqtProperty(str, fget=_get_accent, notify=accentChanged)

    def _get_accent2(self):
        return self._accent2

    accent2 = pyqtProperty(str, fget=_get_accent2, notify=accentChanged)

    def _get_rows(self):
        return self._scanner.rows

    rows = pyqtProperty("QVariantList", fget=_get_rows, notify=rowsChanged)

    # ---- tunable UI settings (all notify uiChanged)
    def _get_wave_intensity(self):
        return float(self._set["waveIntensity"])

    waveIntensity = pyqtProperty(float, fget=_get_wave_intensity,
                                 notify=uiChanged)

    def _get_wave_speed(self):
        return float(self._set["waveSpeed"])

    waveSpeed = pyqtProperty(float, fget=_get_wave_speed, notify=uiChanged)

    def _get_glass_refr(self):
        return float(self._set["glassRefr"])

    glassRefr = pyqtProperty(float, fget=_get_glass_refr, notify=uiChanged)

    def _get_glass_tint(self):
        return float(self._set["glassTint"])

    glassTint = pyqtProperty(float, fget=_get_glass_tint, notify=uiChanged)

    def _get_icon_scale(self):
        return float(self._set["iconScale"])

    iconScale = pyqtProperty(float, fget=_get_icon_scale, notify=uiChanged)

    def _get_clock24(self):
        return bool(self._set["clock24"])

    clock24 = pyqtProperty(bool, fget=_get_clock24, notify=uiChanged)

    def _get_show_seconds(self):
        return bool(self._set["showSeconds"])

    showSeconds = pyqtProperty(bool, fget=_get_show_seconds,
                               notify=uiChanged)

    def _get_city(self):
        return str(self._set["city"])

    city = pyqtProperty(str, fget=_get_city, notify=uiChanged)

    def _get_blank_min(self):
        return int(self._set["blankMin"])

    blankMin = pyqtProperty(int, fget=_get_blank_min, notify=uiChanged)

    def _get_night_mode(self):
        return bool(self._set["nightMode"])

    nightMode = pyqtProperty(bool, fget=_get_night_mode, notify=uiChanged)

    def _get_cursor_autohide(self):
        return bool(self._set["cursorAutohide"])

    cursorAutohide = pyqtProperty(bool, fget=_get_cursor_autohide,
                                  notify=uiChanged)

    def _get_cursor_delay(self):
        return int(self._set["cursorDelay"])

    cursorDelay = pyqtProperty(int, fget=_get_cursor_delay, notify=uiChanged)

    def _get_cursor_size(self):
        return int(self._set["cursorSize"])

    cursorSize = pyqtProperty(int, fget=_get_cursor_size, notify=uiChanged)

    # ---- media
    def _get_media_active(self):
        return self._media_active

    mediaActive = pyqtProperty(bool, fget=_get_media_active,
                               notify=mediaChanged)

    def _get_media_title(self):
        return self._media_title

    mediaTitle = pyqtProperty(str, fget=_get_media_title,
                              notify=mediaChanged)

    def _get_media_artist(self):
        return self._media_artist

    mediaArtist = pyqtProperty(str, fget=_get_media_artist,
                               notify=mediaChanged)

    def _get_media_status(self):
        return self._media_status

    mediaStatus = pyqtProperty(str, fget=_get_media_status,
                               notify=mediaChanged)

    def _get_media_pos(self):
        return self._media_pos

    mediaPos = pyqtProperty(int, fget=_get_media_pos,
                            notify=mediaPosChanged)

    def _get_media_len(self):
        return self._media_len

    mediaLen = pyqtProperty(int, fget=_get_media_len,
                            notify=mediaPosChanged)

    # ---- volume / brightness / weather
    def _get_volume(self):
        return self._volume

    volume = pyqtProperty(int, fget=_get_volume, notify=volumeChanged)

    def _get_muted(self):
        return self._muted

    muted = pyqtProperty(bool, fget=_get_muted, notify=volumeChanged)

    def _get_brightness(self):
        return self._brightness

    brightness = pyqtProperty(int, fget=_get_brightness,
                              notify=brightnessChanged)

    def _get_weather(self):
        return self._weather

    weather = pyqtProperty(str, fget=_get_weather, notify=weatherChanged)

    # ---- window state
    def _get_app_covered(self):
        return self._app_covered

    appCovered = pyqtProperty(bool, fget=_get_app_covered,
                              notify=stateChanged)

    def _get_pip_active(self):
        return self._pip_active

    pipActive = pyqtProperty(bool, fget=_get_pip_active,
                             notify=stateChanged)

    def _get_pip_name(self):
        return self._pip_name

    pipAppName = pyqtProperty(str, fget=_get_pip_name, notify=stateChanged)

    def _get_running_ids(self):
        return self._running_ids

    runningIds = pyqtProperty("QVariantList", fget=_get_running_ids,
                              notify=stateChanged)

    # ---- network / bt / display / about
    def _get_sinks(self):
        return self._sinks

    sinks = pyqtProperty("QVariantList", fget=_get_sinks, notify=netChanged)

    def _get_cur_sink(self):
        return self._cur_sink

    curSink = pyqtProperty(str, fget=_get_cur_sink, notify=netChanged)

    def _get_res_list(self):
        return self._res_list

    resList = pyqtProperty("QVariantList", fget=_get_res_list,
                           notify=netChanged)

    def _get_wifi_enabled(self):
        return self._wifi_enabled

    wifiEnabled = pyqtProperty(bool, fget=_get_wifi_enabled,
                               notify=netChanged)

    def _get_wifi_list(self):
        return self._wifi_list

    wifiList = pyqtProperty("QVariantList", fget=_get_wifi_list,
                            notify=netChanged)

    def _get_cur_ssid(self):
        return self._cur_ssid

    curSsid = pyqtProperty(str, fget=_get_cur_ssid, notify=netChanged)

    def _get_bt_powered(self):
        return self._bt_powered

    btPowered = pyqtProperty(bool, fget=_get_bt_powered, notify=btChanged)

    def _get_bt_devices(self):
        return self._bt_devices

    btDevices = pyqtProperty("QVariantList", fget=_get_bt_devices,
                             notify=btChanged)

    def _get_sys_info(self):
        return self._sys_info

    sysInfo = pyqtProperty(str, fget=_get_sys_info, notify=sysInfoChanged)

    def _get_toast_text(self):
        return self._last_toast

    toastText = pyqtProperty(str, fget=_get_toast_text,
                             notify=toastArrived)

    def _do_toast(self, msg):
        self._last_toast = str(msg)
        self.toastArrived.emit()

    def _get_sw_render(self):
        return self._sw_render_flag

    _sw_render_flag = (os.environ.get("QT_QUICK_BACKEND") == "software")
    swRender = pyqtProperty(bool, fget=_get_sw_render,
                            notify=swRenderChanged)

    def detect_renderer(self, win):
        """True when Qt Quick is on the CPU rasterizer (no GPU shaders)."""
        soft = False
        try:
            api = win.rendererInterface().graphicsApi()
            soft = (api == QSGRendererInterface.Software)
        except Exception:
            soft = (os.environ.get("QT_QUICK_BACKEND") == "software"
                    or os.environ.get("QT_QPA_PLATFORM") == "offscreen")
        if soft != self._sw_render_flag:
            self._sw_render_flag = soft
            self.swRenderChanged.emit()
        log("Render backend: %s" % ("SOFTWARE" if soft else "GPU (OpenGL)"))

    # ------------------------------------------------------------ theme
    @staticmethod
    def _derive_accent2(hex_color):
        c = QColor(hex_color)
        if not c.isValid():
            return "#f97316"
        h, s, l, a = c.getHslF()
        c2 = QColor.fromHslF((h + 0.07) % 1.0, min(1.0, s),
                             min(0.92, l + 0.22), a)
        return c2.name()

    @pyqtSlot(str)
    def setAccent(self, color):
        c = str(color).strip()
        if not QColor(c).isValid():
            return
        self._set["accent"] = c
        self._accent = c
        self._accent2 = self._derive_accent2(c)
        self._save_settings()
        self.accentChanged.emit()
        log("Theme accent -> %s" % c)

    # ---- tuning slots
    @pyqtSlot(float)
    def setWaveIntensity(self, v):
        self._put("waveIntensity", float(max(0.1, min(2.0, float(v)))))

    @pyqtSlot(float)
    def setWaveSpeed(self, v):
        self._put("waveSpeed", float(max(0.1, min(3.0, float(v)))))

    @pyqtSlot(float)
    def setGlassRefr(self, v):
        self._put("glassRefr", float(max(0.0, min(0.05, float(v)))))

    @pyqtSlot(float)
    def setGlassTint(self, v):
        self._put("glassTint", float(max(0.0, min(0.6, float(v)))))

    @pyqtSlot(float)
    def setIconScale(self, v):
        self._put("iconScale", float(max(0.7, min(1.4, float(v)))))

    @pyqtSlot(bool)
    def setClock24(self, v):
        self._put("clock24", bool(v))

    @pyqtSlot(bool)
    def setShowSeconds(self, v):
        self._put("showSeconds", bool(v))

    @pyqtSlot(str)
    def setCity(self, c):
        self._put("city", str(c).strip())
        self._wx_wake.set()

    @pyqtSlot(bool)
    def setNight(self, v):
        self._put("nightMode", bool(v))
        self._apply_night()

    @pyqtSlot(int)
    def setBlank(self, m):
        self._put("blankMin", int(max(0, min(60, int(m)))))
        self._apply_blank()

    @pyqtSlot(bool)
    def setCursorAutohide(self, v):
        self._put("cursorAutohide", bool(v))

    @pyqtSlot(int)
    def setCursorDelay(self, s):
        self._put("cursorDelay", int(max(1, min(30, int(s)))))

    @pyqtSlot(int)
    def setCursorSize(self, px):
        self._put("cursorSize", int(max(12, min(96, int(px)))))
        self._apply_cursor_size()

    def _apply_night(self):
        if not self._have_xrandr or _selftest_mode:
            return
        g = "1.0:0.80:0.62" if self._set["nightMode"] else "1.0:1.0:1.0"
        for o in self._xrandr_outputs():
            subprocess.Popen(["xrandr", "--output", o, "--gamma", g],
                             stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL)

    def _apply_blank(self):
        if _selftest_mode or not shutil.which("xset"):
            return
        m = int(self._set["blankMin"])
        try:
            if m <= 0:
                subprocess.Popen(["xset", "s", "off"],
                                 stdout=subprocess.DEVNULL,
                                 stderr=subprocess.DEVNULL)
                subprocess.Popen(["xset", "-dpms"],
                                 stdout=subprocess.DEVNULL,
                                 stderr=subprocess.DEVNULL)
            else:
                s = str(m * 60)
                subprocess.Popen(["xset", "s", s, s],
                                 stdout=subprocess.DEVNULL,
                                 stderr=subprocess.DEVNULL)
                subprocess.Popen(["xset", "+dpms"],
                                 stdout=subprocess.DEVNULL,
                                 stderr=subprocess.DEVNULL)
        except Exception:
            pass

    def _apply_cursor_size(self):
        px = int(self._set["cursorSize"])
        os.environ["XCURSOR_SIZE"] = str(px)
        if self._have_xrdb and not _selftest_mode:
            try:
                subprocess.run(["xrdb", "-merge"],
                               input=("Xcursor.size: %d\n" % px).encode(),
                               timeout=4)
            except Exception:
                pass

    # ------------------------------------------------------------ app launch
    @pyqtSlot(str, str)
    def launchApp(self, app_id, mode):
        mode = str(mode) if str(mode) in ("full", "float", "left", "right") \
            else "full"
        entry = self._apps_by_id.get(str(app_id))
        if not entry:
            self._do_toast("Unknown application")
            return
        # already running?
        for wid, e in self._wins.items():
            if e["app_id"] == str(app_id):
                log("launchApp: '%s' already running (mode=%s) -> %s"
                    % (app_id, e["mode"], mode))
                if mode == "float":
                    # user asked for PiP on a running app -> float it
                    if e["bg"]:
                        self._sh(["xdotool", "windowmap", str(wid)], 2)
                        e["bg"] = False
                    e["mode"] = "float"
                    self._apply_mode(wid, "float")
                    self._emit_state()
                else:
                    self.backToApp(str(app_id))
                return
        cmd = "exec " + entry["exec"]
        try:
            p = subprocess.Popen(
                ["/bin/sh", "-c", cmd],
                cwd=os.path.expanduser("~"),
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                start_new_session=True)
            self._tracked.append(p.pid)
            if len(self._tracked) > 32:
                self._tracked = self._tracked[-32:]
            self._pending.append({"pid": p.pid, "app_id": str(app_id),
                                  "name": entry["name"], "mode": mode,
                                  "until": time.time() + 25})
            log("Launched '%s' mode=%s (pid %d)"
                % (entry["name"], mode, p.pid))
        except Exception as exc:
            log("Launch failed for %s: %s" % (entry["name"], exc))
            self._do_toast("Could not launch " + entry["name"])
            return
        # quick sweeps so the window snaps into place fast
        QTimer.singleShot(600, self._watch_windows)
        QTimer.singleShot(1600, self._watch_windows)
        QTimer.singleShot(3400, self._watch_windows)

    def _kill_tracked(self):
        for pid in list(self._tracked):
            try:
                os.killpg(pid, signal.SIGTERM)
            except Exception:
                try:
                    os.kill(pid, signal.SIGTERM)
                except Exception:
                    pass

        def reap():
            for pid in list(self._tracked):
                if not _pid_alive(pid):
                    continue
                try:
                    os.killpg(pid, signal.SIGKILL)
                except Exception:
                    pass

        QTimer.singleShot(1500, reap)

    # ------------------------------------------------------------ kiosk enforcer
    @staticmethod
    def _net_wm_pid(wid):
        try:
            out = subprocess.run(
                ["xprop", "-id", hex(wid), "-notype", "_NET_WM_PID"],
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                timeout=3).stdout.decode("utf-8", "ignore")
            m = re.search(r"=\s*(\d+)", out)
            return int(m.group(1)) if m else 0
        except Exception:
            return 0

    @staticmethod
    def _pid_matches(npid, lpid):
        if not lpid:
            return False
        if npid and npid == lpid:
            return True
        if npid and _pgid_of(npid) == lpid:
            return True
        # shell wrapper may have already exec'd / children of children
        if npid and lpid and _pgid_of(npid) and _pgid_of(lpid) \
                and _pgid_of(npid) == _pgid_of(lpid):
            return True
        return False

    def _watch_windows(self):
        if self._stop or not self._have_xdotool:
            return
        own = self._own_win_id()
        ids = set()
        for args in (["xdotool", "search", "--onlyvisible", "--name", ""],
                     ["xdotool", "search", "--onlyvisible", "--class", ""]):
            out = self._sh(args, 4)
            for tok in out.split():
                try:
                    ids.add(int(tok))
                except ValueError:
                    pass
        geo = QGuiApplication.primaryScreen().geometry()
        W, H = geo.width(), geo.height()
        now = time.time()

        # drop dead pending launches
        self._pending = [p for p in self._pending if p["until"] > now]

        # refresh state of tracked windows
        for wid, e in list(self._wins.items()):
            if wid in ids:
                e["bg"] = False
            else:
                e["bg"] = _pid_alive(e["pid"])
                if not e["bg"] and now > e.get("gone_until", 0):
                    self._wins.pop(wid, None)

        # adopt new foreign windows
        for wid in ids:
            if not wid or wid == own or wid in self._wins:
                continue
            name = self._sh(["xdotool", "getwindowname", str(wid)], 2).strip()
            if not name or "aura" in name.lower():
                continue
            cls = self._sh(["xdotool", "getwindowclassname", str(wid)],
                           2).strip().lower()
            if not cls or "aura" in cls or cls in self.DESKTOP_CLASSES:
                continue
            xp = self._sh(["xprop", "-id", hex(wid), "-notype",
                           "WM_TRANSIENT_FOR", "_NET_WM_WINDOW_TYPE"], 3)
            if "WM_TRANSIENT_FOR" in xp and "0x0" not in xp:
                continue  # dialogs / tooltips of the app itself
            if any(t in xp for t in ("_NET_WM_WINDOW_TYPE_DOCK",
                                     "_NET_WM_WINDOW_TYPE_NOTIFICATION",
                                     "_NET_WM_WINDOW_TYPE_DESKTOP")):
                continue
            mode, aid, nm, pid = "full", "", "", 0
            npid = self._net_wm_pid(wid)
            for p in list(self._pending):
                if self._pid_matches(npid, p["pid"]):
                    mode, aid, nm, pid = (p["mode"], p["app_id"],
                                          p["name"], p["pid"])
                    self._pending.remove(p)
                    break
            else:
                pid = npid
            self._wins[wid] = {"mode": mode, "app_id": aid, "name": nm,
                               "pid": pid, "bg": False, "ts": now,
                               "gone_until": 0}
            if aid:
                self._last_aid = aid
            log("Adopted window %#x '%s' mode=%s" % (wid, name, mode))
            if mode in ("left", "right"):
                # split screen: any fullscreen app moves to the opposite half
                opp = "right" if mode == "left" else "left"
                for w2, e2 in self._wins.items():
                    if w2 != wid and e2["mode"] == "full":
                        e2["mode"] = opp
                        self._apply_mode(w2, opp)
            self._apply_mode(wid, mode)

        # re-assert fullscreen on fresh or drifted full-mode windows
        for wid, e in self._wins.items():
            if e["mode"] != "full" or e["bg"] or wid not in ids:
                continue
            if (now - e["ts"]) < 8.0 or self._geometry_drifted(wid, W, H):
                self._force_full(wid, W, H)

        # float windows keep the always-on-top flag
        if self._have_wmctrl:
            for wid, e in self._wins.items():
                if e["mode"] == "float" and not e["bg"] and wid in ids:
                    self._sh(["wmctrl", "-i", "-r", hex(wid), "-b",
                              "add,above"], 2)

        self._last_visible = ids
        self._emit_state(ids)

    def _geometry_drifted(self, wid, W, H):
        out = self._sh(["xdotool", "getwindowgeometry", "--shell",
                        str(wid)], 2)
        m = re.search(r"WIDTH=(\d+)", out)
        m2 = re.search(r"HEIGHT=(\d+)", out)
        if not m or not m2:
            return False
        return int(m.group(1)) != W or int(m2.group(1)) != H

    def _force_full(self, wid, W, H):
        s = str(wid)
        h = hex(wid)
        self._undecorate(h)
        if self._have_wmctrl:
            self._sh(["wmctrl", "-i", "-r", h, "-b", "add,fullscreen"], 2)
        self._sh(["xdotool", "windowmove", s, "0", "0"], 2)
        self._sh(["xdotool", "windowsize", s, str(W), str(H)], 2)
        self._sh(["xdotool", "windowfocus", s], 2)

    def _undecorate(self, hex_wid):
        """Strip decorations under any window manager (MOTIF hints)."""
        self._sh(["xprop", "-id", hex_wid, "-f", "_MOTIF_WM_HINTS", "32c",
                  "-set", "_MOTIF_WM_HINTS", "0x2, 0x0, 0x0, 0x0, 0x0"], 2)

    def _apply_mode(self, wid, mode):
        s = str(wid)
        h = hex(wid)
        self._undecorate(h)
        if self._have_wmctrl:
            self._sh(["wmctrl", "-i", "-r", h,
                      "-b", "remove,maximized_vert,maximized_horz"], 2)
            self._sh(["wmctrl", "-i", "-r", h,
                      "-b", "remove,fullscreen,above"], 2)
        geo = QGuiApplication.primaryScreen().geometry()
        W, H = geo.width(), geo.height()
        if mode == "full":
            self._force_full(wid, W, H)
            return
        if mode == "float":
            w = int(W * 0.30)
            hh = int(w * 9 / 16)
            x = max(0, W - w - 24)
            y = 24
            self._sh(["xdotool", "windowmove", s, str(x), str(y)], 2)
            self._sh(["xdotool", "windowsize", s, str(w), str(hh)], 2)
            if self._have_wmctrl:
                self._sh(["wmctrl", "-i", "-r", h, "-b", "add,above"], 2)
        elif mode in ("left", "right"):
            x = 0 if mode == "left" else W // 2
            self._sh(["xdotool", "windowmove", s, str(x), "0"], 2)
            self._sh(["xdotool", "windowsize", s, str(W // 2), str(H)], 2)
        self._sh(["xdotool", "windowfocus", s], 2)

    def _emit_state(self, ids=None):
        if ids is None:
            ids = getattr(self, "_last_visible", set())
        covered = any(e["mode"] == "full" and not e["bg"] and wid in ids
                      for wid, e in self._wins.items())
        pip_name = ""
        for wid, e in self._wins.items():
            if e["mode"] == "float" and not e["bg"] and wid in ids:
                pip_name = e["name"] or pip_name
        running = sorted({e["app_id"] for wid, e in self._wins.items()
                          if e["app_id"] and (e["bg"] or wid in ids)})
        changed = (covered != self._app_covered
                   or bool(pip_name) != self._pip_active
                   or pip_name != self._pip_name
                   or running != self._running_ids)
        self._app_covered = covered
        self._pip_active = bool(pip_name)
        self._pip_name = pip_name
        self._running_ids = running
        if changed:
            self.stateChanged.emit()

    # ------------------------------------------------------------ home
    @pyqtSlot()
    def onHomePress(self):
        """Debounced universal home: single = background + return,
        double (within 450ms) = close PiP + Control Center."""
        now = time.monotonic()
        if self._home_single_timer.isActive() and \
                (now - self._last_home) <= 0.60:
            self._home_single_timer.stop()
            self._last_home = 0.0
            log("HOME double-press")
            self.onHomeDouble()
        else:
            self._last_home = now
            self._home_single_timer.start()

    @pyqtSlot()
    def onHome(self):
        """Single Home: background running apps, return to the shell."""
        log("HOME single press - backgrounding apps")
        self.homeTap.emit()
        for wid, e in self._wins.items():
            if e["mode"] in ("full", "left", "right") and not e["bg"]:
                self._sh(["xdotool", "windowunmap", str(wid)], 2)
                e["bg"] = True
        QTimer.singleShot(80, self._raise_self)
        self._emit_state()

    @pyqtSlot()
    def onHomeDouble(self):
        """Double Home: close PiP + open Control Center over any app."""
        for wid, e in list(self._wins.items()):
            if e["mode"] == "float":
                self._close_wid(wid)
        QTimer.singleShot(80, self._raise_self)
        self.homeDoubleTap.emit()

    @pyqtSlot(str)
    def backToApp(self, app_id=""):
        app_id = str(app_id)
        targets = [(wid, e) for wid, e in self._wins.items()
                   if e["mode"] in ("full", "left", "right")
                   and (not app_id or e["app_id"] == app_id)]
        if not targets:
            return
        last = None
        for wid, e in targets:
            if e["bg"]:
                self._sh(["xdotool", "windowmap", str(wid)], 2)
                e["bg"] = False
            self._apply_mode(wid, e["mode"])
            last = wid
        if last:
            if self._have_wmctrl:
                self._sh(["wmctrl", "-i", "-a", hex(last)], 2)
            self._sh(["xdotool", "windowfocus", str(last)], 2)
            self._last_aid = self._wins[last]["app_id"] or self._last_aid
        self._emit_state()

    @pyqtSlot(str)
    def closeApp(self, app_id):
        app_id = str(app_id)
        pids = set()
        for wid, e in list(self._wins.items()):
            if e["app_id"] == app_id:
                self._close_wid(wid)
                if e["pid"]:
                    pids.add(e["pid"])
        for pid in pids:
            QTimer.singleShot(2000, lambda p=pid: self._sigterm_pid(p))

    @pyqtSlot(str)
    def pipAction(self, action):
        act = str(action)
        pipw = None
        for wid, e in self._wins.items():
            if e["mode"] == "float":
                pipw = wid
                break
        if act == "close":
            if pipw is not None:
                self._close_wid(pipw)
            return
        if pipw is None:
            return
        if act in ("left", "right"):
            opp = "right" if act == "left" else "left"
            for w2, e2 in self._wins.items():
                if e2["mode"] == "full":
                    e2["mode"] = opp
                    self._apply_mode(w2, opp)
            self._wins[pipw]["mode"] = act
            self._apply_mode(pipw, act)
        elif act == "full":
            self._wins[pipw]["mode"] = "full"
            self._apply_mode(pipw, "full")
        self._emit_state()

    def _close_wid(self, wid):
        if self._have_wmctrl:
            self._sh(["wmctrl", "-i", "-c", hex(wid)], 2)
        e = self._wins.get(wid)
        if e:
            e["gone_until"] = time.time() + 2.5

        def force():
            if wid in self._wins and _pid_alive(self._wins[wid]["pid"]):
                self._sh(["xdotool", "windowkill", str(wid)], 2)
                self._sigterm_pid(self._wins[wid]["pid"])
            if wid in self._wins:
                del self._wins[wid]
                self._emit_state()
        QTimer.singleShot(1800, force)

    def _sigterm_pid(self, pid):
        if not _pid_alive(pid):
            return
        try:
            os.killpg(pid, signal.SIGTERM)
        except Exception:
            try:
                os.kill(pid, signal.SIGTERM)
            except Exception:
                pass

    def _raise_self(self):
        wid = self._own_win_id()
        if wid and self._have_xdotool:
            self._sh(["xdotool", "windowraise", str(wid)], 2)
            self._sh(["xdotool", "windowfocus", str(wid)], 2)
            geo = QGuiApplication.primaryScreen().geometry()
            self._force_full(wid, geo.width(), geo.height())
        try:
            self._own_win.raise_()
            self._own_win.requestActivate()
        except Exception:
            pass

    def _ensure_xbindkeys(self):
        if not os.environ.get("DISPLAY"):
            return
        if not shutil.which("xbindkeys"):
            return
        if self._sh(["pgrep", "-x", "xbindkeys"], 2).strip():
            return
        cfg = os.path.join(AURA_DIR, "xbindkeysrc")
        if os.path.exists(cfg):
            subprocess.Popen(["xbindkeys", "-f", cfg],
                             stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL)
            log("xbindkeys started (Super/Home -> Aura overlay)")

    def _fifo_loop(self):
        global FIFO_PATH
        try:
            os.makedirs(RUNTIME_DIR, exist_ok=True)
            if not os.path.exists(FIFO_PATH):
                os.mkfifo(FIFO_PATH, 0o600)
        except Exception:
            import tempfile
            fifo_dir = os.path.join(tempfile.gettempdir(),
                                    "aura-os-%d" % os.getuid())
            try:
                os.makedirs(fifo_dir, exist_ok=True)
                FIFO_PATH = os.path.join(fifo_dir, "home.fifo")
                if not os.path.exists(FIFO_PATH):
                    os.mkfifo(FIFO_PATH, 0o600)
            except Exception as exc:
                log("FIFO unavailable (%s) - universal home disabled" % exc)
                return
        log("Home control FIFO at %s" % FIFO_PATH)
        while not self._stop:
            try:
                with open(FIFO_PATH, "rb") as f:
                    while not self._stop:
                        line = f.readline()
                        if not line:
                            break
                        cmd = line.decode("utf-8", "ignore").strip()
                        if cmd == "HOME":
                            self.homeRequested.emit()
            except Exception:
                time.sleep(1.0)

    # ------------------------------------------------------------ media widget
    def _media_poll(self):
        if self._stop:
            return
        players = self._sh(["playerctl", "--list-all"], 2).strip()
        if not players:
            if self._media_active:
                self._media_active = False
                self._media_title = ""
                self._media_len = 0
                self.mediaChanged.emit()
            return
        meta = self._sh(["playerctl", "metadata", "--format", self.MEDIA_FMT],
                        2).strip()
        if not meta:
            if self._media_active:
                self._media_active = False
                self.mediaChanged.emit()
            return
        parts = (meta.split("|") + ["", "", "", "", ""])[:5]
        _player, title, artist, status, length = [p.strip() for p in parts]
        changed = (not self._media_active or title != self._media_title
                   or artist != self._media_artist
                   or status != self._media_status)
        self._media_active = True
        self._media_title = title or "Unknown track"
        self._media_artist = artist
        self._media_status = status or "Playing"
        try:
            us = float(length)
            ln = int(us / 1000000.0)
        except Exception:
            ln = 0
        if ln != self._media_len:
            self._media_len = ln
            self.mediaPosChanged.emit()
        if changed:
            self.mediaChanged.emit()

    def _media_pos_poll(self):
        if self._stop or not self._media_active:
            return
        out = self._sh(["playerctl", "position"], 2).strip()
        try:
            pos = int(float(out))
        except Exception:
            return
        if pos != self._media_pos:
            self._media_pos = pos
            self.mediaPosChanged.emit()

    @pyqtSlot(str)
    def mediaAction(self, action):
        mapping = {"toggle": "play-pause", "next": "next",
                   "prev": "previous", "stop": "stop"}
        act = mapping.get(str(action))
        if not act:
            return
        subprocess.Popen(["playerctl", act],
                         stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL)
        QTimer.singleShot(400, self._media_poll)

    @pyqtSlot(int)
    def mediaSeek(self, seconds):
        try:
            subprocess.Popen(["playerctl", "position", str(int(seconds))],
                             stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL)
        except Exception:
            pass
        QTimer.singleShot(500, self._media_pos_poll)

    # ------------------------------------------------------------ volume
    def _volume_refresh(self):
        if self._stop:
            return
        vol, mute = None, None
        if self._have_pactl:
            out = self._sh(["pactl", "get-sink-volume", "@DEFAULT_SINK@"], 2)
            m = re.search(r"(\d+)%", out)
            if m:
                vol = int(m.group(1))
            mo = self._sh(["pactl", "get-sink-mute", "@DEFAULT_SINK@"], 2)
            mute = "yes" in mo.lower()
        if vol is None and self._have_amixer:
            out = self._sh(["amixer", "get", "Master"], 2)
            m = re.search(r"\[(\d+)%\]", out)
            if m:
                vol = int(m.group(1))
                mute = "[off]" in out
        if vol is not None:
            changed = (vol != self._volume or bool(mute) != self._muted)
            self._volume = vol
            self._muted = bool(mute)
            if changed:
                self.volumeChanged.emit()

    def _vol_ctl(self, args_pactl, args_amixer):
        try:
            if self._have_pactl:
                subprocess.Popen(["pactl"] + args_pactl,
                                 stdout=subprocess.DEVNULL,
                                 stderr=subprocess.DEVNULL)
            elif self._have_amixer:
                subprocess.Popen(["amixer", "-q"] + args_amixer,
                                 stdout=subprocess.DEVNULL,
                                 stderr=subprocess.DEVNULL)
        except Exception:
            pass
        QTimer.singleShot(300, self._volume_refresh)

    @pyqtSlot(int)
    def setVolume(self, v):
        v = int(max(0, min(100, int(v))))
        self._volume = v
        self._muted = False
        self.volumeChanged.emit()
        self._vol_ctl(["set-sink-volume", "@DEFAULT_SINK@", "%d%%" % v],
                      ["set", "Master", "%d%%" % v])

    @pyqtSlot()
    def volumeUp(self):
        self.setVolume(self._volume + 5)

    @pyqtSlot()
    def volumeDown(self):
        self.setVolume(self._volume - 5)

    @pyqtSlot()
    def volumeMute(self):
        self._vol_ctl(["set-sink-mute", "@DEFAULT_SINK@", "toggle"],
                      ["set", "Master", "toggle"])

    # ------------------------------------------------------------ brightness
    def _xrandr_outputs(self):
        out = self._sh(["xrandr", "--current"], 3)
        outs = []
        for line in out.splitlines():
            m = re.match(r"^(\S+)\s+connected", line)
            if m:
                outs.append(m.group(1))
        return outs

    def _brightness_refresh(self):
        if self._stop or not self._have_xrandr:
            return
        out = self._sh(["xrandr", "--current", "--verbose"], 4)
        cur_out, val = None, None
        for line in out.splitlines():
            m = re.match(r"^(\S+)\s+connected", line)
            if m:
                cur_out = m.group(1)
                continue
            if cur_out and val is None:
                mb = re.match(r"^\s*Brightness:\s*([0-9.]+)", line)
                if mb:
                    val = float(mb.group(1))
        if val is not None:
            pct = int(round(val * 100))
            if pct != self._brightness:
                self._brightness = pct
                self.brightnessChanged.emit()

    @pyqtSlot(int)
    def setBrightness(self, pct):
        if not self._have_xrandr:
            return
        val = max(0.15, min(1.0, int(pct) / 100.0))
        for o in self._xrandr_outputs():
            subprocess.Popen(["xrandr", "--output", o,
                              "--brightness", "%.2f" % val],
                             stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL)
        self._brightness = int(round(val * 100))
        self.brightnessChanged.emit()

    @pyqtSlot()
    def brightnessUp(self):
        self.setBrightness(self._brightness + 10)

    @pyqtSlot()
    def brightnessDown(self):
        self.setBrightness(self._brightness - 10)

    # ------------------------------------------------------------ display
    @pyqtSlot()
    def refreshRes(self):
        threading.Thread(target=self._res_refresh, daemon=True).start()

    def _res_refresh(self):
        if not self._have_xrandr:
            return
        out = self._sh(["xrandr", "--current"], 5)
        modes = {}
        order = []
        out_name = None
        for line in out.splitlines():
            m = re.match(r"^(\S+)\s+connected", line)
            if m:
                out_name = m.group(1)
                continue
            if not out_name:
                continue
            m2 = re.match(r"^\s+(\d+)x(\d+)\s+(.*)$", line)
            if not m2:
                continue
            wh = "%sx%s" % (m2.group(1), m2.group(2))
            rates = m2.group(3).split()
            best, cur = None, False
            for tok in rates:
                starred = "*" in tok
                try:
                    r = float(tok.strip("*+ "))
                except Exception:
                    continue
                if best is None or starred:
                    best = r
                if starred:
                    cur = True
            if best is None:
                continue
            if wh not in modes:
                modes[wh] = {"mode": wh, "rate": ("%.2f" % best),
                             "current": False}
                order.append(wh)
            if cur:
                modes[wh]["current"] = True
        lst = [modes[wh] for wh in order]
        with self._net_lock:
            self._res_list = lst
            self.netChanged.emit()

    @pyqtSlot(str, str)
    def setRes(self, mode, rate):
        if not self._have_xrandr:
            return
        outs = self._xrandr_outputs()
        for o in outs:
            subprocess.Popen(["xrandr", "--output", o, "--mode", str(mode),
                              "--rate", str(rate)],
                             stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL)
        self._do_toast("Resolution: %s @ %s Hz" % (mode, rate))
        QTimer.singleShot(1500, self._res_refresh)

    # ------------------------------------------------------------ sound sinks
    @pyqtSlot()
    def refreshSinks(self):
        threading.Thread(target=self._sinks_refresh, daemon=True).start()

    def _sinks_refresh(self):
        if not self._have_pactl:
            return
        descs = {}
        out = self._sh(["pactl", "list", "sinks"], 5)
        for m in re.finditer(r"Sink #\d+.*?(?=Sink #|\Z)", out, re.S):
            blk = m.group(0)
            nm = re.search(r"^\s*Name:\s*(\S+)", blk, re.M)
            ds = re.search(r"^\s*Description:\s*(.*)$", blk, re.M)
            if nm:
                descs[nm.group(1)] = ds.group(1).strip() if ds else nm.group(1)
        lst = []
        for nm in descs:
            lst.append({"name": nm, "desc": descs[nm]})
        cur = self._sh(["pactl", "info"], 3)
        m = re.search(r"Default Sink:\s*(\S+)", cur)
        curs = m.group(1) if m else ""
        with self._net_lock:
            self._sinks = lst
            self._cur_sink = curs
            self.netChanged.emit()

    @pyqtSlot(str)
    def setSink(self, name):
        if self._have_pactl:
            subprocess.Popen(["pactl", "set-default-sink", str(name)],
                             stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL)
            QTimer.singleShot(500, self.refreshSinks)

    # ------------------------------------------------------------ network
    @pyqtSlot()
    def refreshWifi(self):
        threading.Thread(target=self._wifi_refresh, daemon=True).start()

    def _wifi_refresh(self):
        if not self._have_nmcli:
            return
        out = self._sh(["nmcli", "radio", "wifi"], 4).strip()
        enabled = out.endswith("enabled")
        self._sh(["nmcli", "device", "wifi", "rescan"], 4)
        time.sleep(0.8)
        out = self._sh(["nmcli", "-t", "-f", "IN-USE,SSID,SIGNAL,SECURITY",
                        "device", "wifi", "list"], 8)
        nets = []
        for line in out.splitlines():
            f = line.split(":")
            if len(f) < 4:
                continue
            inuse = (f[0] == "*")
            sec = f[-1]
            try:
                sig = int(f[-2])
            except Exception:
                sig = 0
            ssid = ":".join(f[1:-2]).strip()
            if not ssid:
                continue
            nets.append({"ssid": ssid, "signal": sig,
                         "secured": sec not in ("", "--"), "active": inuse})
        nets.sort(key=lambda n: (not n["active"], -n["signal"]))
        cur = self._sh(["nmcli", "-t", "-f", "NAME,TYPE",
                        "connection", "show", "--active"], 4)
        cssid = ""
        for line in cur.splitlines():
            f = line.split(":")
            if len(f) >= 2 and "wireless" in f[1]:
                cssid = f[0]
                break
        with self._net_lock:
            self._wifi_enabled = enabled
            self._wifi_list = nets
            self._cur_ssid = cssid
            self.netChanged.emit()

    @pyqtSlot(bool)
    def wifiToggle(self, on):
        if not self._have_nmcli:
            return
        subprocess.Popen(["nmcli", "radio", "wifi",
                          "on" if on else "off"],
                         stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL)
        QTimer.singleShot(1500, self.refreshWifi)

    @pyqtSlot(bool)
    def setAirplane(self, on):
        if not self._have_nmcli:
            return
        subprocess.Popen(["nmcli", "radio", "all", "off" if on else "on"],
                         stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL)
        QTimer.singleShot(2000, self.refreshWifi)

    @pyqtSlot(str, str)
    def connectWifi(self, ssid, password):
        ssid = str(ssid)
        pw = str(password)

        def work():
            if not self._have_nmcli:
                self.toast.emit("NetworkManager unavailable")
                return
            args = ["nmcli", "device", "wifi", "connect", ssid]
            if pw:
                args += ["password", pw]
            rc, err = self._run_rc(args, 30)
            if rc == 0:
                self._do_toast("Connected to " + ssid)
            else:
                msg = (err or "").strip().splitlines()
                self._do_toast("Wi-Fi failed: " +
                               (msg[-1][:60] if msg else "error"))
            self._wifi_refresh()
        threading.Thread(target=work, daemon=True).start()

    @pyqtSlot()
    def wifiDisconnect(self):
        if not self._have_nmcli or not self._cur_ssid:
            return
        subprocess.Popen(["nmcli", "connection", "down", self._cur_ssid],
                         stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL)
        QTimer.singleShot(1200, self.refreshWifi)

    # ------------------------------------------------------------ bluetooth
    @pyqtSlot()
    def refreshBt(self):
        threading.Thread(target=self._bt_refresh, daemon=True).start()

    def _bt_refresh(self):
        if not self._have_bt:
            return
        out = self._sh(["bluetoothctl", "show"], 4)
        powered = "Powered: yes" in out
        devs = []
        out = self._sh(["bluetoothctl", "devices"], 5)
        for line in out.splitlines():
            m = re.match(r"Device\s+(\S+)\s+(.*)$", line.strip())
            if not m:
                continue
            mac, nm = m.group(1), m.group(2)
            info = self._sh(["bluetoothctl", "info", mac], 3)
            conn = "Connected: yes" in info
            devs.append({"mac": mac, "name": nm, "connected": conn})
        with self._net_lock:
            self._bt_powered = powered
            self._bt_devices = devs
            self.btChanged.emit()

    @pyqtSlot(bool)
    def btToggle(self, on):
        if not self._have_bt:
            return
        subprocess.Popen(["bluetoothctl", "power", "on" if on else "off"],
                         stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL)
        QTimer.singleShot(1200, self.refreshBt)

    @pyqtSlot()
    def btScan(self):
        if not self._have_bt:
            return

        def work():
            try:
                p = subprocess.Popen(["bluetoothctl", "scan", "on"],
                                     stdout=subprocess.DEVNULL,
                                     stderr=subprocess.DEVNULL)
                time.sleep(8)
                p.terminate()
            except Exception:
                pass
            self._bt_refresh()
        threading.Thread(target=work, daemon=True).start()
        self._do_toast("Scanning for devices...")

    @pyqtSlot(str)
    def btConnect(self, mac):
        def work():
            rc, err = self._run_rc(["bluetoothctl", "connect", str(mac)], 15)
            self._do_toast("Connected" if rc == 0
                           else "Bluetooth connect failed")
            self._bt_refresh()
        threading.Thread(target=work, daemon=True).start()

    @pyqtSlot(str)
    def btDisconnect(self, mac):
        def work():
            self._run_rc(["bluetoothctl", "disconnect", str(mac)], 10)
            self._bt_refresh()
        threading.Thread(target=work, daemon=True).start()

    # ------------------------------------------------------------ power
    @pyqtSlot(str)
    def powerAction(self, action):
        act = str(action)
        if act not in ("suspend", "reboot", "poweroff"):
            return
        log("Power action: %s" % act)
        try:
            subprocess.Popen(["systemctl", act],
                             stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL)
        except Exception as exc:
            log("Power action failed: %s" % exc)

    @pyqtSlot()
    def screenOff(self):
        if shutil.which("xset"):
            subprocess.Popen(["xset", "dpms", "force", "off"],
                             stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL)

    @pyqtSlot()
    def logout(self):
        log("Logout requested - ending Aura session")
        self._stop = True
        for wid, e in list(self._wins.items()):
            self._sh(["xdotool", "windowunmap", str(wid)], 1)
        self._kill_tracked()
        QTimer.singleShot(150, QGuiApplication.quit)

    # ------------------------------------------------------------ weather
    def _weather_loop(self):
        try:
            with open(WEATHER_FILE, "r") as f:
                data = json.load(f)
            txt = str(data.get("text", "")).strip()
            if txt:
                self._weather = txt
                self.weatherChanged.emit()
        except Exception:
            pass
        while not self._stop:
            txt = self._weather_fetch()
            if txt:
                self._weather = txt
                self.weatherChanged.emit()
                try:
                    os.makedirs(CACHE_DIR, exist_ok=True)
                    with open(WEATHER_FILE, "w") as f:
                        json.dump({"text": txt, "ts": time.time()}, f)
                except Exception:
                    pass
                self._wx_wake.wait(900)
            else:
                if self._weather.startswith("Weather starting"):
                    self._weather = "Weather unavailable"
                    self.weatherChanged.emit()
                self._wx_wake.wait(300)
            self._wx_wake.clear()

    def _weather_fetch(self):
        try:
            fmt = "%l: %C, %t"
            city = str(self._set.get("city", "")).strip()
            url = ("https://wttr.in/" + quote(city) if city
                   else "https://wttr.in")
            url += "?format=" + quote(fmt)
            req = urlrequest.Request(url, headers={"User-Agent": "curl/8.0"})
            with urlrequest.urlopen(req, timeout=7) as resp:
                txt = resp.read().decode("utf-8", "ignore").strip()
            if txt and len(txt) < 160 and "Unknown" not in txt \
                    and "Sorry" not in txt:
                return txt
        except Exception:
            return ""
        return ""

    # ------------------------------------------------------------ about
    @pyqtSlot()
    def refreshSysInfo(self):
        threading.Thread(target=self._sysinfo_build, daemon=True).start()

    def _sysinfo_build(self):
        lines = []
        try:
            with open("/etc/os-release") as f:
                m = re.search(r'PRETTY_NAME="?([^"\n]+)', f.read())
            lines.append("System: " + (m.group(1) if m else "Linux"))
        except Exception:
            lines.append("System: Linux")
        try:
            un = os.uname()
            lines.append("Kernel: %s %s" % (un.sysname, un.release))
            lines.append("Host: %s" % un.nodename)
        except Exception:
            pass
        try:
            out = self._sh(["lspci"], 4)
            for ln in out.splitlines():
                if re.search(r"VGA|3D controller|Display", ln):
                    parts = ln.split(":", 2)
                    if len(parts) == 3:
                        lines.append("GPU: " + parts[2].strip())
                    break
        except Exception:
            pass
        try:
            with open("/proc/cpuinfo") as f:
                m = re.search(r"model name\s*:\s*(.+)", f.read())
            if m:
                lines.append("CPU: " + m.group(1).strip())
        except Exception:
            pass
        try:
            with open("/proc/meminfo") as f:
                m = re.search(r"MemTotal:\s+(\d+)", f.read())
            if m:
                lines.append("Memory: %.1f GB"
                             % (int(m.group(1)) / 1048576.0))
        except Exception:
            pass
        try:
            geo = QGuiApplication.primaryScreen().geometry()
            lines.append("Display: %dx%d" % (geo.width(), geo.height()))
        except Exception:
            pass
        try:
            with open("/proc/uptime") as f:
                up = int(float(f.read().split()[0]))
            lines.append("Uptime: %dh %dm" % (up // 3600, (up % 3600) // 60))
        except Exception:
            pass
        lines.append("Shell: Aura OS v%s" % APP_VERSION)
        self._sys_info = "\n".join(lines)
        self.sysInfoChanged.emit()

    # ------------------------------------------------------------ misc slots
    @pyqtSlot()
    def rescan(self):
        self._scanner.scan()
        self.rowsChanged.emit()


# ---------------------------------------------------------------------------
# Mouse autohide (configurable delay, default 5s)
# ---------------------------------------------------------------------------

class AutoHideFilter(QObject):
    def __init__(self, app, bridge):
        super(AutoHideFilter, self).__init__()
        self._app = app
        self._bridge = bridge
        self._hidden = False
        self._timer = QTimer()
        self._timer.setSingleShot(True)
        self._timer.timeout.connect(self._hide)

    def start(self):
        self._timer.setInterval(max(1, self._bridge.cursorDelay) * 1000)
        self._timer.start()

    def _hide(self):
        if not self._hidden and self._bridge.cursorAutohide:
            self._hidden = True
            QGuiApplication.setOverrideCursor(QCursor(Qt.BlankCursor))

    def _show(self):
        self._timer.setInterval(max(1, self._bridge.cursorDelay) * 1000)
        self._timer.start()
        if self._hidden:
            self._hidden = False
            QGuiApplication.restoreOverrideCursor()

    def eventFilter(self, obj, event):
        t = event.type()
        if t in (QEvent.MouseMove, QEvent.MouseButtonPress,
                 QEvent.MouseButtonRelease, QEvent.Wheel,
                 QEvent.KeyPress, QEvent.KeyRelease,
                 QEvent.TabletMove, QEvent.TouchUpdate):
            self._show()
        return False


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

def main():
    QGuiApplication.setAttribute(Qt.AA_ShareOpenGLContexts, True)
    app = QGuiApplication(sys.argv)
    app.setApplicationName("aura-os")
    app.setApplicationDisplayName(APP_NAME)
    app.setOrganizationName("AuraOS")

    signal.signal(signal.SIGTERM, lambda *_: app.quit())
    signal.signal(signal.SIGINT, lambda *_: app.quit())

    bridge = AuraBridge(app)  # parented to the app: lifetime insurance

    engine = QQmlApplicationEngine()
    engine.warnings.connect(
        lambda lst: [log("QML: %s" % w.toString()) for w in lst])
    engine.addImageProvider("auraicons", IconProvider(
        bridge._scanner.icons_by_key, bridge))
    ctx = engine.rootContext()
    ctx.setContextProperty("bridge", bridge)
    ctx.setContextProperty("auraVersion", APP_VERSION)
    qml_path = os.path.join(AURA_DIR, "ui.qml")
    engine.load(QUrl.fromLocalFile(qml_path))
    if not engine.rootObjects():
        sys.stderr.write("FATAL: QML engine failed to load %s\n" % qml_path)
        sys.exit(3)
    win = engine.rootObjects()[0]
    bridge.attach_window(win)
    bridge.detect_renderer(win)
    bridge.start()

    if _selftest_mode:
        def _ok():
            log("AURA_SELFTEST_OK")
            app.quit()
        QTimer.singleShot(1500, _ok)
        rc = app.exec_()
        sys.exit(0 if rc == 0 else 4)

    autohide = AutoHideFilter(app, bridge)
    app.installEventFilter(autohide)
    autohide.start()

    bridge.homeRequested.connect(bridge.onHomePress)
    app.aboutToQuit.connect(bridge.shutdown)

    log("Aura OS shell running (v%s)" % APP_VERSION)
    sys.exit(app.exec_())


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception:
        import traceback
        traceback.print_exc()
        sys.exit(1)
AURA_MAIN_PY_EOF


cat > "$AURA_DIR/ui.qml" <<'AURA_UI_QML_EOF'
/***************************************************************************
 * AURA OS - Native Kiosk Shell (frontend, Qt Quick / QML) v2 "Glass"
 *  - ONE global PS3-style wave layer (GPU fragment shader, full screen)
 *  - True glass refraction: every panel/card BENDS the background behind
 *    it (SDF refraction + RGB chromatic dispersion), like real glass
 *  - TV carousel: pinned left labels, horizontal track shift, vertical
 *    row centering, edge fades, hover follows the mouse exactly
 *  - Long-press / right-click a tile -> quick menu (Open / PiP / halves)
 *  - Control Center + full-screen Settings app (TV UI), PiP controls
 ***************************************************************************/
import QtQuick 2.12
import QtQuick.Window 2.12
import QtGraphicalEffects 1.0

Window {
    id: win
    objectName: "AuraOSWindow"
    visible: true
    visibility: Window.FullScreen
    width: Screen.width
    height: Screen.height
    color: "#030409"
    title: "Aura OS"

    // ------------------------------ state
    property color accent: bridge.accent
    property color accent2: bridge.accent2
    property bool isSoftware: bridge.swRender
    property bool ccOpen: false
    property bool settingsOpen: false
    property bool pwOpen: false
    property bool menuOpen: false
    property var menuApp: null
    property bool menuIsPip: false
    property var menuModel: []
    property string pwTargetSsid: ""
    property int selRow: 0
    property int selCol: 0
    property real mouseX: -1
    property real mouseY: -1
    property bool mouseMode: false

    property real iconScale: bridge.iconScale
    property int cardW: Math.round(176 * iconScale)
    property int cardH: Math.round(226 * iconScale)
    property int cardGap: Math.round(16 * iconScale)
    property int rowH: cardH + 34
    property int rowGap: 26
    property int rowPad: 200
    property int trackX: 316

    function clamp(v, a, b) { return Math.max(a, Math.min(b, v)) }
    function rowCount(i) {
        if (!bridge.rows || bridge.rows.length === 0) return 0
        var r = bridge.rows[clamp(i, 0, bridge.rows.length - 1)]
        return r.apps.length
    }
    function select(r, c) {
        if (!bridge.rows || bridge.rows.length === 0) return
        selRow = clamp(r, 0, bridge.rows.length - 1)
        selCol = clamp(c, 0, rowCount(selRow) - 1)
    }
    function trackOffFor(appCount) {
        var trackW = win.width - win.trackX - 48
        return clamp(win.selCol * (win.cardW + win.cardGap) - 44,
                     0,
                     Math.max(0, appCount * (win.cardW + win.cardGap)
                              - win.cardGap - trackW))
    }
    function selectedApp() {
        if (!bridge.rows || bridge.rows.length === 0) return null
        var row = bridge.rows[selRow]
        if (!row || row.apps.length === 0) return null
        return row.apps[clamp(selCol, 0, row.apps.length - 1)]
    }
    // Re-sync the selection to the card actually under the mouse cursor.
    function syncHover() {
        if (!mouseMode || ccOpen || settingsOpen || pwOpen || menuOpen)
            return
        if (bridge.appCovered) return
        if (!bridge.rows || bridge.rows.length === 0) return
        var r = Math.floor((mouseY + rowsFlick.contentY - rowPad
                            + rowH * 0.45) / (rowH + rowGap))
        r = clamp(r, 0, bridge.rows.length - 1)
        var toff = trackOffFor(bridge.rows[r].apps.length)
        var c = Math.floor((mouseX - trackX + toff) / (cardW + cardGap))
        c = clamp(c, 0, bridge.rows[r].apps.length - 1)
        if (r !== selRow || c !== selCol) select(r, c)
    }
    function launchAt(app, mode) {
        if (!app) return
        flashLaunch()
        bridge.launchApp(app.id, mode)
    }
    function closeAllOverlays() {
        ccOpen = false
        settingsOpen = false
        menuOpen = false
        pwOpen = false
    }
    // ---- quick menu (long-press / right-click / PiP chip)
    function openAppMenu(item, app) {
        var running = bridge.runningIds.indexOf(app.id) >= 0
        var items = [
            { t: "Open Fullscreen", a: "full" },
            { t: "Float as PiP (top-right)", a: "float" },
            { t: "Fill Left Half", a: "left" },
            { t: "Fill Right Half", a: "right" }
        ]
        if (running)
            items.push({ t: "Bring to Front", a: "front" },
                       { t: "Close App", a: "close" })
        menuApp = app
        menuIsPip = false
        menuModel = items
        var p = item.mapToItem(contentRoot, item.width / 2, item.height)
        showMenuAt(p.x, p.y)
    }
    function openPipMenu(item) {
        menuApp = null
        menuIsPip = true
        menuModel = [
            { t: "Make Fullscreen", a: "full" },
            { t: "Fill Left Half", a: "left" },
            { t: "Fill Right Half", a: "right" },
            { t: "Close PiP", a: "close" }
        ]
        var p = item.mapToItem(contentRoot, item.width / 2, item.height)
        showMenuAt(p.x, p.y)
    }
    function showMenuAt(x, y) {
        menuOpen = true
        appMenu.x = clamp(x - appMenu.width / 2, 12, win.width - appMenu.width - 12)
        var estH = menuModel.length * 48 + 70
        var yy = y + 14
        if (yy + estH > win.height - 16) yy = y - estH - 14
        appMenu.y = clamp(yy, 12, Math.max(12, win.height - appMenu.height - 12))
    }
    function menuAction(a) {
        var app = menuApp
        var isPip = menuIsPip
        menuOpen = false
        if (isPip) { bridge.pipAction(a); return }
        if (!app) return
        if (a === "front") bridge.backToApp(app.id)
        else if (a === "close") bridge.closeApp(app.id)
        else launchAt(app, a)
    }

    // ------------------------------ shaders
    // Explicit vertex shader: guarantees qt_UV on every Qt 5.x + driver
    // combo, and exports clip-space NDC for screen-space glass sampling.
    property string effectVert:
        "uniform mat4 qt_Matrix;" +
        "attribute vec4 qt_Vertex;" +
        "attribute vec2 qt_MultiTexCoord0;" +
        "varying vec2 qt_UV;" +
        "varying vec2 vNdc;" +
        "void main() { qt_UV = qt_MultiTexCoord0;" +
        "  gl_Position = qt_Matrix * qt_Vertex;" +
        "  vNdc = gl_Position.xy / max(gl_Position.w, 0.0001); }"

    property string waveFrag:
        "varying vec2 qt_UV;" +
        "uniform float t;" +
        "uniform float uIntensity;" +
        "uniform vec4 cA;" +
        "uniform vec4 cB;" +
        "const vec3 EDGE = vec3(0.01176, 0.01569, 0.03529);" +
        "float ry(float x, float f, float sp, float ph, float amp, float base){" +
        "  return base + amp*(0.62*sin(x*f + t*sp + ph)" +
        "        + 0.38*sin(x*f*2.17 + t*sp*1.37 + ph*1.71)" +
        "        + 0.18*sin(x*f*4.31 + t*sp*0.61 + ph*0.5)); }" +
        "void main(){" +
        "  vec2 uv = qt_UV;" +
        "  vec3 col = mix(vec3(0.010,0.014,0.032), vec3(0.024,0.034,0.078), uv.y);" +
        "  float y0 = ry(uv.x, 3.4, 0.42, 0.0, 0.085, 0.60);" +
        "  float y1 = ry(uv.x, 4.6, 0.30, 2.1, 0.120, 0.47);" +
        "  float y2 = ry(uv.x, 3.0, 0.24, 4.2, 0.100, 0.34);" +
        "  float b0 = pow(0.014/(abs(uv.y-y0)+0.014), 2.4);" +
        "  float b1 = pow(0.020/(abs(uv.y-y1)+0.020), 2.2);" +
        "  float b2 = pow(0.016/(abs(uv.y-y2)+0.016), 2.6);" +
        "  vec3 wc = mix(cA.rgb, cB.rgb, clamp(uv.x*0.75 + uv.y*0.25, 0.0, 1.0));" +
        "  col += wc * (b0*0.85 + b1*0.55 + b2*0.40) * 0.50 * uIntensity;" +
        "  col += wc * pow(b0, 6.0) * 0.35 * uIntensity;" +
        "  float edge = smoothstep(0.0, 0.13, uv.y) * (1.0 - smoothstep(0.87, 1.0, uv.y));" +
        "  col = mix(EDGE, col, edge);" +
        "  float vig = distance(uv, vec2(0.5, 0.46));" +
        "  col *= 1.0 - vig*vig*0.5;" +
        "  gl_FragColor = vec4(col, 1.0); }"

    // Glass refraction: screen-space sampling of the single background
    // layer; UV bent along the rounded-box normal near the edges (the
    // glass "lens"), RGB split for chromatic dispersion, fresnel rim,
    // PREMULTIPLIED alpha (kills the grey-corner fringe).
    property string glassFrag:
        "varying vec2 qt_UV;" +
        "varying vec2 vNdc;" +
        "uniform sampler2D srcTex;" +
        "uniform vec2 uCard;" +
        "uniform float uRadius;" +
        "uniform vec4 uTint;" +
        "uniform vec4 uAccent;" +
        "uniform float uRefr;" +
        "uniform float uGlow;" +
        "float rrect(vec2 p, vec2 b, float r){" +
        "  vec2 q = abs(p) - b + vec2(r);" +
        "  return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r; }" +
        "vec2 sdn(vec2 p, vec2 b, float r){" +
        "  vec2 cw = clamp(p, -(b - vec2(r)), b - vec2(r));" +
        "  vec2 d = p - cw;" +
        "  float l = length(d);" +
        "  return (l > 0.0001) ? d / l : vec2(0.0); }" +
        "void main(){" +
        "  vec2 px = qt_UV * uCard;" +
        "  vec2 ctr = uCard * 0.5;" +
        "  vec2 lp = px - ctr;" +
        "  float d = rrect(lp, ctr, uRadius);" +
        "  float edge = 1.0 - smoothstep(0.0, uCard.y * 0.5 * 0.22, -d);" +
        "  vec2 n = sdn(lp, ctr, uRadius);" +
        "  vec2 scr = vec2(0.5 + 0.5 * vNdc.x, 0.5 - 0.5 * vNdc.y);" +
        "  scr = (scr - 0.5) * (1.0 - 0.012 * (1.0 - edge)) + 0.5;" +
        "  vec2 off = n * edge * uRefr;" +
        "  vec2 su = clamp(scr + off, vec2(0.002), vec2(0.998));" +
        "  vec2 ru = clamp(su + off * 0.45, vec2(0.002), vec2(0.998));" +
        "  vec2 bu = clamp(su - off * 0.45, vec2(0.002), vec2(0.998));" +
        "  vec3 col;" +
        "  col.r = texture2D(srcTex, ru).r;" +
        "  col.g = texture2D(srcTex, su).g;" +
        "  col.b = texture2D(srcTex, bu).b;" +
        "  col = mix(col, uTint.rgb, uTint.a * (0.45 + 0.40 * (1.0 - qt_UV.y)));" +
        "  col += vec3(1.0) * 0.045 * pow(1.0 - qt_UV.y, 3.0);" +
        "  float rim = 1.0 - smoothstep(0.5, 7.0, -d);" +
        "  col += uAccent.rgb * rim * (0.16 + 0.55 * uGlow);" +
        "  float alpha = (1.0 - smoothstep(-0.5, 1.5, d)) * 0.94;" +
        "  gl_FragColor = vec4(col * alpha, alpha); }"

    // ------------------------------ graphics backend detection
    Component.onCompleted: {
        contentRoot.forceActiveFocus()
        logMsg("backend software=" + win.isSoftware)
    }
    function logMsg(m) { console.log("[aura.qml] " + m) }

    // ============================== BACKGROUND: PS3-style wave ==============
    Rectangle {
        id: bgRoot
        anchors.fill: parent
        color: "#030409"

        ShaderEffect {
            id: waveFx
            anchors.fill: parent
            visible: !win.isSoftware
            vertexShader: win.effectVert
            property real t: 0
            property real uIntensity: bridge.waveIntensity
            property color cA: win.accent
            property color cB: win.accent2
            fragmentShader: win.waveFrag

            Timer {
                interval: 16
                running: waveFx.visible && !bridge.appCovered
                repeat: true
                onTriggered: waveFx.t += 0.016 * Math.max(0.1, bridge.waveSpeed)
            }
        }

        // CPU fallback (software rendering / VMs without GL)
        Canvas {
            id: waveCanvas
            anchors.fill: parent
            visible: win.isSoftware
            property real t: 0
            onPaint: {
                var ctx = getContext("2d")
                ctx.reset()
                var w = width, h = height
                var grd = ctx.createLinearGradient(0, 0, 0, h)
                grd.addColorStop(0, "#030409")
                grd.addColorStop(1, "#070a16")
                ctx.fillStyle = grd
                ctx.fillRect(0, 0, w, h)
                for (var i = 0; i < 3; i++) {
                    ctx.beginPath()
                    var baseY = h * (0.40 + i * 0.12)
                    for (var x = 0; x <= w; x += 20) {
                        var y = baseY
                                + Math.sin(x / 150 + t * (0.7 + i * 0.25) + i * 2.1) * (30 + i * 16)
                                + Math.sin(x / 61 + t * 0.9 + i) * 10
                        if (x === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y)
                    }
                    ctx.strokeStyle = Qt.rgba(win.accent.r, win.accent.g, win.accent.b, 0.30 - i * 0.08)
                    ctx.lineWidth = 12 - i * 3
                    ctx.stroke()
                }
            }
            Timer {
                interval: 66
                running: waveCanvas.visible
                repeat: true
                onTriggered: { waveCanvas.t += 0.066; waveCanvas.requestPaint() }
            }
        }
    }

    // ============================== GLASS FEED ==============================
    // Sits fully behind the opaque bgRoot (z:-1) so it always renders,
    // while every glass surface samples its texture in SCREEN space.
    Item {
        id: glassFeed
        anchors.fill: parent
        z: -1
        visible: !win.isSoftware

        ShaderEffectSource {
            id: bgSource
            sourceItem: bgRoot
            anchors.fill: parent
            smooth: true
            recursive: false
            textureSize: Qt.size(Math.max(1, bgRoot.width / 2),
                                 Math.max(1, bgRoot.height / 2))
        }
    }

    // ============================== CONTENT: carousel ========================
    Item {
        id: contentRoot
        anchors.fill: parent
        focus: true
        z: 1
        transformOrigin: Item.Center
        // Dim is DERIVED from live window state: it always brightens back
        // to 1.0 the moment the last app window is gone (fixes stuck dim).
        opacity: bridge.appCovered ? 0.14 : 1.0
        scale: bridge.appCovered ? 0.965 : 1.0
        Behavior on opacity { NumberAnimation { duration: 420; easing.type: Easing.OutCubic } }
        Behavior on scale { NumberAnimation { duration: 420; easing.type: Easing.OutCubic } }

        // hover tracker: NoButton => never blocks clicks; keeps the glow
        // locked onto the card actually under the cursor
        MouseArea {
            id: hoverTracker
            anchors.fill: parent
            acceptedButtons: Qt.NoButton
            hoverEnabled: true
            onPositionChanged: {
                win.mouseX = mouse.x
                win.mouseY = mouse.y
                win.mouseMode = true
                win.syncHover()
            }
            onEntered: { win.mouseMode = true; win.syncHover() }
            onWheel: {
                win.mouseMode = true
                if (wheel.angleDelta.y < 0) win.select(win.selRow + 1, win.selCol)
                else if (wheel.angleDelta.y > 0) win.select(win.selRow - 1, win.selCol)
                if (wheel.angleDelta.x > 0) win.select(win.selRow, win.selCol + 1)
                else if (wheel.angleDelta.x < 0) win.select(win.selRow, win.selCol - 1)
            }
        }

        Flickable {
            id: rowsFlick
            anchors.fill: parent
            interactive: false
            clip: false

            contentY: {
                if (!bridge.rows || bridge.rows.length === 0) return 0
                var t = win.rowPad + win.selRow * (win.rowH + win.rowGap)
                        - (height - win.rowH) / 2
                return win.clamp(t, 0, Math.max(0, rowsCol.height - height))
            }
            Behavior on contentY {
                NumberAnimation { duration: 420; easing.type: Easing.OutCubic }
            }

            Item {
                id: rowsCol
                x: 0
                y: 0
                width: rowsFlick.width
                height: win.rowPad * 2
                        + (bridge.rows ? bridge.rows.length : 0) * (win.rowH + win.rowGap)

                Repeater {
                    model: bridge.rows

                    // ---------------- one category row -------------------
                    Item {
                        id: rowRoot
                        property int rowIndex: index
                        property var rowData: modelData
                        property bool rowActive: rowIndex === win.selRow
                        property real trackW: win.width - win.trackX - 48
                        property real trackOff:
                            win.clamp(win.selCol * (win.cardW + win.cardGap) - 44,
                                      0,
                                      Math.max(0,
                                          rowData.apps.length * (win.cardW + win.cardGap)
                                          - win.cardGap - trackW))

                        y: win.rowPad + rowIndex * (win.rowH + win.rowGap)
                        width: parent.width
                        height: win.rowH

                        Behavior on trackOff {
                            NumberAnimation { duration: 430; easing.type: Easing.OutCubic }
                        }

                        // -- pinned left label column
                        Rectangle {
                            x: 48
                            width: 3
                            height: 44
                            radius: 2
                            color: win.accent
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.verticalCenterOffset: -6
                            opacity: rowRoot.rowActive ? 0.95 : 0.15
                            Behavior on opacity { NumberAnimation { duration: 260 } }
                        }
                        Text {
                            x: 66
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.verticalCenterOffset: -22
                            text: rowRoot.rowData.name
                            color: rowRoot.rowActive ? win.accent : Qt.rgba(1, 1, 1, 0.45)
                            font.pixelSize: 26
                            font.weight: Font.DemiBold
                            font.letterSpacing: 1
                            Behavior on color { ColorAnimation { duration: 260 } }
                        }
                        Text {
                            x: 66
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.verticalCenterOffset: 8
                            text: rowRoot.rowData.apps.length + " apps"
                            color: Qt.rgba(1, 1, 1, 0.30)
                            font.pixelSize: 12
                            font.letterSpacing: 2
                        }

                        // -- horizontal shifting track
                        Item {
                            id: track
                            x: win.trackX
                            y: (parent.height - win.cardH) / 2
                            width: parent.width - win.trackX - 48
                            height: win.cardH

                            Repeater {
                                model: rowRoot.rowData.apps

                                // ------------------- app card ------------
                                Item {
                                    id: cardRoot
                                    property int colIndex: index
                                    property var appData: modelData
                                    property bool isFocused:
                                        rowRoot.rowIndex === win.selRow
                                        && colIndex === win.selCol
                                    property bool isRunning:
                                        bridge.runningIds.indexOf(appData.id) >= 0
                                    property real pos:
                                        colIndex * (win.cardW + win.cardGap)
                                        - rowRoot.trackOff

                                    x: pos
                                    width: win.cardW
                                    height: win.cardH

                                    opacity: {
                                        var o = 1.0
                                        if (pos < 0) o = win.clamp(1 + pos / 150, 0, 1)
                                        var tail = pos + win.cardW - track.width
                                        if (tail > 0)
                                            o = Math.min(o, win.clamp(1 - tail / 150, 0, 1))
                                        return o * (rowRoot.rowActive ? 1.0 : 0.30)
                                    }
                                    scale: {
                                        var s = 1.0
                                        if (pos < 0) s = win.clamp(1 + pos / 1100, 0.84, 1.0)
                                        return s * (isFocused ? 1.09 : 1.0)
                                                * (rowRoot.rowActive ? 1.0 : 0.97)
                                    }
                                    Behavior on scale { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }

                                    // frosted refracting glass body (GPU)
                                    ShaderEffect {
                                        anchors.fill: parent
                                        visible: !win.isSoftware
                                        vertexShader: win.effectVert
                                        property var srcTex: bgSource
                                        property vector2d uCard:
                                            Qt.vector2d(cardRoot.width, cardRoot.height)
                                        property real uRadius: 22
                                        property color uTint:
                                            Qt.rgba(0.62, 0.68, 0.82, 0.10 + bridge.glassTint)
                                        property color uAccent: win.accent
                                        property real uRefr: bridge.glassRefr
                                        property real uGlow: cardRoot.isFocused ? 1.0 : 0.0
                                        fragmentShader: win.glassFrag
                                    }
                                    // software fallback body
                                    Rectangle {
                                        anchors.fill: parent
                                        visible: win.isSoftware
                                        radius: 22
                                        color: Qt.rgba(0.10, 0.12, 0.20, 0.85)
                                        border.color: cardRoot.isFocused
                                                      ? win.accent : Qt.rgba(1, 1, 1, 0.12)
                                        border.width: cardRoot.isFocused ? 2 : 1
                                    }

                                    // running badge
                                    Rectangle {
                                        x: parent.width - 22
                                        y: 10
                                        width: 11
                                        height: 11
                                        radius: 5.5
                                        color: "#34d399"
                                        border.color: Qt.rgba(1, 1, 1, 0.55)
                                        border.width: 1
                                        visible: cardRoot.isRunning
                                    }

                                    // icon
                                    Item {
                                        id: iconWrap
                                        width: Math.round(96 * win.iconScale)
                                        height: width
                                        x: (parent.width - width) / 2
                                        y: 22
                                        Image {
                                            anchors.fill: parent
                                            anchors.margins: 8
                                            source: "image://auraicons/" + cardRoot.appData.key
                                            fillMode: Image.PreserveAspectFit
                                            smooth: true
                                            mipmap: true
                                            asynchronous: false
                                            sourceSize: Qt.size(96, 96)
                                        }
                                    }

                                    // label
                                    Text {
                                        x: 12
                                        width: parent.width - 24
                                        y: parent.height - 88
                                        text: cardRoot.appData.name
                                        color: cardRoot.isFocused
                                               ? "#ffffff" : Qt.rgba(1, 1, 1, 0.72)
                                        font.pixelSize: 14
                                        font.weight: Font.DemiBold
                                        horizontalAlignment: Text.AlignHCenter
                                        elide: Text.ElideRight
                                        maximumLineCount: 2
                                        wrapMode: Text.Wrap
                                    }

                                    MouseArea {
                                        anchors.fill: parent
                                        hoverEnabled: false
                                        acceptedButtons: Qt.LeftButton | Qt.RightButton
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            if (mouse.button === Qt.RightButton) {
                                                win.openAppMenu(cardRoot, cardRoot.appData)
                                                return
                                            }
                                            win.select(rowRoot.rowIndex, cardRoot.colIndex)
                                            win.launchAt(cardRoot.appData, "full")
                                        }
                                        onPressAndHold: {
                                            win.select(rowRoot.rowIndex, cardRoot.colIndex)
                                            win.openAppMenu(cardRoot, cardRoot.appData)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // -- edge fading (top & bottom gradient masks)
        Rectangle {
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            height: 150
            z: 2
            gradient: Gradient {
                GradientStop { position: 0.0; color: Qt.rgba(0.01176, 0.01569, 0.03529, 0.95) }
                GradientStop { position: 1.0; color: Qt.rgba(0.01176, 0.01569, 0.03529, 0.0) }
            }
        }
        Rectangle {
            anchors.bottom: parent.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            height: 180
            z: 2
            gradient: Gradient {
                GradientStop { position: 0.0; color: Qt.rgba(0.01176, 0.01569, 0.03529, 0.0) }
                GradientStop { position: 1.0; color: Qt.rgba(0.01176, 0.01569, 0.03529, 0.95) }
            }
        }

        // ---- keyboard / TV remote navigation
        Keys.onPressed: {
            if (event.key === Qt.Key_Escape) {
                if (win.menuOpen) { win.menuOpen = false }
                else if (win.pwOpen) { win.pwOpen = false }
                else if (win.settingsOpen) { win.settingsOpen = false }
                else { win.ccOpen = !win.ccOpen }
                event.accepted = true
            } else if (event.key === Qt.Key_Q && (event.modifiers & Qt.ControlModifier)) {
                Qt.quit()
                event.accepted = true
            } else if (event.key === Qt.Key_Left) {
                win.mouseMode = false
                win.select(win.selRow, win.selCol - 1); event.accepted = true
            } else if (event.key === Qt.Key_Right) {
                win.mouseMode = false
                win.select(win.selRow, win.selCol + 1); event.accepted = true
            } else if (event.key === Qt.Key_Up) {
                win.mouseMode = false
                win.select(win.selRow - 1, win.selCol); event.accepted = true
            } else if (event.key === Qt.Key_Down) {
                win.mouseMode = false
                win.select(win.selRow + 1, win.selCol); event.accepted = true
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                       || event.key === Qt.Key_Select) {
                win.launchAt(win.selectedApp(), "full"); event.accepted = true
            }
        }
    }

    // ============================== LAUNCH FLASH =============================
    Rectangle {
        id: launchFlash
        anchors.fill: parent
        color: win.accent
        opacity: 0
        z: 7
        visible: opacity > 0.001
    }
    SequentialAnimation {
        id: flashAnim
        NumberAnimation { target: launchFlash; property: "opacity"; from: 0; to: 0.40; duration: 110 }
        NumberAnimation { target: launchFlash; property: "opacity"; from: 0.40; to: 0; duration: 460; easing.type: Easing.OutCubic }
    }
    function flashLaunch() { flashAnim.restart() }

    // ============================== TOP-LEFT HEADER ==========================
    Item {
        id: headerPanel
        z: 3
        x: 28
        y: 24
        width: 356
        height: 96
        opacity: bridge.appCovered ? 0.0 : 1.0
        Behavior on opacity { NumberAnimation { duration: 350 } }

        ShaderEffect {
            anchors.fill: parent
            visible: !win.isSoftware
            vertexShader: win.effectVert
            property var srcTex: bgSource
            property vector2d uCard: Qt.vector2d(headerPanel.width, headerPanel.height)
            property real uRadius: 24
            property color uTint: Qt.rgba(0.62, 0.68, 0.82, 0.10 + bridge.glassTint)
            property color uAccent: win.accent
            property real uRefr: bridge.glassRefr
            property real uGlow: 0.0
            fragmentShader: win.glassFrag
        }
        Rectangle {
            anchors.fill: parent
            visible: win.isSoftware
            radius: 24
            color: Qt.rgba(0.10, 0.12, 0.20, 0.82)
        }

        property string timeText: "00:00"
        property string dateText: ""
        Timer {
            interval: 1000
            running: true
            repeat: true
            triggeredOnStart: true
            onTriggered: {
                var now = new Date()
                var fmt = bridge.clock24 ? "HH:mm" : "h:mm ap"
                if (bridge.showSeconds)
                    fmt = bridge.clock24 ? "HH:mm:ss" : "h:mm:ss ap"
                headerPanel.timeText = Qt.formatDateTime(now, fmt)
                headerPanel.dateText = Qt.formatDate(now, "dddd, d MMMM")
            }
        }

        Text {
            id: clock
            x: 24
            anchors.verticalCenter: parent.verticalCenter
            text: headerPanel.timeText
            color: "#f4f6fb"
            font.pixelSize: 42
            font.weight: Font.Bold
            font.letterSpacing: 2
        }
        Rectangle {
            x: 158
            y: 22
            width: 1
            height: parent.height - 44
            color: Qt.rgba(1, 1, 1, 0.14)
        }
        Text {
            x: 178
            y: 22
            width: parent.width - 198
            text: bridge.weather
            color: win.accent
            font.pixelSize: 15
            font.weight: Font.DemiBold
            elide: Text.ElideRight
        }
        Text {
            x: 178
            y: 52
            width: parent.width - 198
            text: headerPanel.dateText
            color: Qt.rgba(1, 1, 1, 0.55)
            font.pixelSize: 13
            elide: Text.ElideRight
        }
    }

    // ============================== TOP-CENTER MEDIA WIDGET ==================
    Item {
        id: mediaPanel
        z: 3
        anchors.horizontalCenter: parent.horizontalCenter
        y: 24
        width: 470
        height: 88
        visible: bridge.mediaActive
        opacity: (bridge.mediaActive ? 1 : 0) * (bridge.appCovered ? 0.0 : 1.0)
        Behavior on opacity { NumberAnimation { duration: 300 } }

        ShaderEffect {
            anchors.fill: parent
            visible: !win.isSoftware && bridge.mediaActive
            vertexShader: win.effectVert
            property var srcTex: bgSource
            property vector2d uCard: Qt.vector2d(mediaPanel.width, mediaPanel.height)
            property real uRadius: 24
            property color uTint: Qt.rgba(0.62, 0.68, 0.82, 0.10 + bridge.glassTint)
            property color uAccent: win.accent
            property real uRefr: bridge.glassRefr
            property real uGlow: 0.0
            fragmentShader: win.glassFrag
        }
        Rectangle {
            anchors.fill: parent
            visible: win.isSoftware
            radius: 24
            color: Qt.rgba(0.10, 0.12, 0.20, 0.82)
        }

        Canvas {
            id: prevIco
            property color fg: Qt.rgba(1, 1, 1, 0.85)
            x: 22; y: 28; width: 26; height: 26
            onPaint: {
                var c = getContext("2d"); c.reset()
                c.fillStyle = fg
                c.beginPath(); c.moveTo(18, 4); c.lineTo(6, 13); c.lineTo(18, 22); c.closePath(); c.fill()
                c.fillRect(3, 4, 3, 18)
            }
            MouseArea { anchors.fill: parent; anchors.margins: -8; onClicked: bridge.mediaAction("prev") }
        }
        Canvas {
            id: playIco
            property bool playing: bridge.mediaStatus === "Playing"
            x: 62; y: 27; width: 28; height: 28
            onPaint: {
                var c = getContext("2d"); c.reset()
                c.fillStyle = win.accent
                if (playing) {
                    c.fillRect(6, 4, 6, 20); c.fillRect(16, 4, 6, 20)
                } else {
                    c.beginPath(); c.moveTo(8, 3); c.lineTo(23, 14); c.lineTo(8, 25); c.closePath(); c.fill()
                }
            }
            onPlayingChanged: requestPaint()
            onVisibleChanged: requestPaint()
            MouseArea { anchors.fill: parent; anchors.margins: -8; onClicked: bridge.mediaAction("toggle") }
        }
        Canvas {
            id: nextIco
            property color fg: Qt.rgba(1, 1, 1, 0.85)
            x: 104; y: 28; width: 26; height: 26
            onPaint: {
                var c = getContext("2d"); c.reset()
                c.fillStyle = fg
                c.beginPath(); c.moveTo(8, 4); c.lineTo(20, 13); c.lineTo(8, 22); c.closePath(); c.fill()
                c.fillRect(20, 4, 3, 18)
            }
            MouseArea { anchors.fill: parent; anchors.margins: -8; onClicked: bridge.mediaAction("next") }
        }

        Text {
            x: 148
            y: 16
            width: parent.width - 168
            text: bridge.mediaTitle
            color: "#f4f6fb"
            font.pixelSize: 15
            font.weight: Font.DemiBold
            elide: Text.ElideRight
        }
        Text {
            x: 148
            y: 42
            width: parent.width - 168
            text: (bridge.mediaArtist !== "" ? bridge.mediaArtist + "  ·  " : "")
                  + bridge.mediaStatus
            color: Qt.rgba(1, 1, 1, 0.55)
            font.pixelSize: 12
            elide: Text.ElideRight
        }
        // seek / progress line
        Rectangle {
            x: 22
            y: parent.height - 18
            width: parent.width - 44
            height: 4
            radius: 2
            color: Qt.rgba(1, 1, 1, 0.14)
            Rectangle {
                width: bridge.mediaLen > 0
                       ? parent.width * win.clamp(bridge.mediaPos / bridge.mediaLen, 0, 1)
                       : 0
                height: parent.height
                radius: 2
                color: win.accent
            }
            MouseArea {
                anchors.fill: parent
                anchors.margins: -8
                onClicked: {
                    if (bridge.mediaLen > 0)
                        bridge.mediaSeek(Math.round((mouse.x / width) * bridge.mediaLen))
                }
            }
        }
    }

    // ============================== TOP-RIGHT PiP CHIP =======================
    Item {
        id: pipChip
        z: 3
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: 24
        width: pipRow.width + 36
        height: 46
        visible: bridge.pipActive
        opacity: bridge.appCovered ? 0.0 : 1.0
        Behavior on opacity { NumberAnimation { duration: 300 } }

        ShaderEffect {
            anchors.fill: parent
            visible: !win.isSoftware
            vertexShader: win.effectVert
            property var srcTex: bgSource
            property vector2d uCard: Qt.vector2d(pipChip.width, pipChip.height)
            property real uRadius: 23
            property color uTint: Qt.rgba(0.62, 0.68, 0.82, 0.12 + bridge.glassTint)
            property color uAccent: win.accent
            property real uRefr: bridge.glassRefr
            property real uGlow: 0.25
            fragmentShader: win.glassFrag
        }
        Rectangle {
            anchors.fill: parent
            visible: win.isSoftware
            radius: 23
            color: Qt.rgba(0.10, 0.12, 0.20, 0.85)
        }
        Row {
            id: pipRow
            x: 18
            anchors.verticalCenter: parent.verticalCenter
            spacing: 10
            Rectangle {
                width: 10; height: 10; radius: 5
                color: "#34d399"
                anchors.verticalCenter: parent.verticalCenter
            }
            Text {
                text: "PiP · " + bridge.pipAppName
                color: "#f4f6fb"
                font.pixelSize: 14
                font.weight: Font.DemiBold
                anchors.verticalCenter: parent.verticalCenter
                elide: Text.ElideRight
            }
        }
        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: win.openPipMenu(pipChip)
        }
    }

    // ============================== BOTTOM-RIGHT WORDMARK ====================
    Text {
        z: 3
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: 22
        text: "AURA OS  ·  v" + auraVersion +
              "  ·  hold an app for options  ·  Home back  ·  Home x2 controls"
        color: Qt.rgba(1, 1, 1, 0.30)
        font.pixelSize: 11
        font.letterSpacing: 2
    }

    // ============================== QUICK MENU (long-press) ==================
    MouseArea {
        z: 8
        anchors.fill: parent
        visible: win.menuOpen
        enabled: win.menuOpen
        onClicked: win.menuOpen = false
    }

    Item {
        id: appMenu
        objectName: "appMenu"
        z: 9
        visible: win.menuOpen
        width: 264
        height: menuCol.height + 22
        x: 100; y: 100

        ShaderEffect {
            anchors.fill: parent
            visible: !win.isSoftware
            vertexShader: win.effectVert
            property var srcTex: bgSource
            property vector2d uCard: Qt.vector2d(appMenu.width, appMenu.height)
            property real uRadius: 18
            property color uTint: Qt.rgba(0.60, 0.66, 0.82, 0.16 + bridge.glassTint)
            property color uAccent: win.accent
            property real uRefr: bridge.glassRefr
            property real uGlow: 0.35
            fragmentShader: win.glassFrag
        }
        Rectangle {
            anchors.fill: parent
            visible: win.isSoftware
            radius: 18
            color: Qt.rgba(0.09, 0.11, 0.19, 0.94)
        }
        // swallow: clicks on the menu body never fall through
        MouseArea { anchors.fill: parent; onClicked: { } }

        Column {
            id: menuCol
            x: 12
            y: 12
            width: parent.width - 24
            spacing: 4

            Text {
                x: 8
                text: win.menuIsPip
                      ? "Picture-in-Picture"
                      : (win.menuApp ? win.menuApp.name : "")
                color: win.accent
                font.pixelSize: 13
                font.weight: Font.Bold
                font.letterSpacing: 1
                elide: Text.ElideRight
                width: parent.width - 16
                bottomPadding: 4
            }
            Repeater {
                model: win.menuModel
                Rectangle {
                    width: menuCol.width
                    height: 44
                    radius: 12
                    color: mq.containsMouse
                           ? Qt.rgba(1, 1, 1, 0.10) : Qt.rgba(1, 1, 1, 0.03)
                    Behavior on color { ColorAnimation { duration: 120 } }
                    Text {
                        x: 14
                        anchors.verticalCenter: parent.verticalCenter
                        text: modelData.t
                        color: "#f4f6fb"
                        font.pixelSize: 14
                    }
                    MouseArea {
                        id: mq
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: win.menuAction(modelData.a)
                    }
                }
            }
        }
    }

    // ============================== CONTROL CENTER (bottom-left) =============
    // outside-click catcher
    MouseArea {
        z: 3
        anchors.fill: parent
        visible: win.ccOpen
        enabled: win.ccOpen
        onClicked: win.ccOpen = false
    }

    // collapsed pill
    Item {
        id: ccPill
        z: 4
        x: 28
        y: parent.height - 84
        width: 220
        height: 56
        visible: opacity > 0.01
        opacity: win.ccOpen ? 0 : 1
        enabled: !win.ccOpen
        scale: win.ccOpen ? 0.92 : 1.0
        Behavior on opacity { NumberAnimation { duration: 240 } }
        Behavior on scale { NumberAnimation { duration: 240; easing.type: Easing.OutBack } }

        Rectangle {
            anchors.fill: parent
            radius: 28
            color: Qt.rgba(0.08, 0.10, 0.17, 0.88)
            border.color: Qt.rgba(1, 1, 1, 0.14)
            border.width: 1
        }
        Canvas {
            x: 20; y: 17; width: 22; height: 22
            onPaint: {
                var c = getContext("2d"); c.reset()
                c.strokeStyle = Qt.rgba(1, 1, 1, 0.85); c.lineWidth = 2
                c.beginPath(); c.moveTo(3, 6); c.lineTo(19, 6); c.stroke()
                c.beginPath(); c.moveTo(3, 15); c.lineTo(19, 15); c.stroke()
                c.fillStyle = win.accent
                c.beginPath(); c.arc(13, 6, 3.4, 0, 6.3); c.fill()
                c.beginPath(); c.arc(8, 15, 3.4, 0, 6.3); c.fill()
            }
        }
        Text {
            x: 52
            anchors.verticalCenter: parent.verticalCenter
            text: "Control Center"
            color: Qt.rgba(1, 1, 1, 0.88)
            font.pixelSize: 15
            font.weight: Font.DemiBold
        }
        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: win.ccOpen = true
        }
    }

    // expanded panel
    Item {
        id: ccPanel
        z: 4
        x: 28
        y: parent.height - height - 28
        width: 470
        height: Math.min(Math.max(430, ccCol.height + 64), parent.height - 40)
        visible: opacity > 0.01
        opacity: win.ccOpen ? 1 : 0
        enabled: win.ccOpen
        scale: win.ccOpen ? 1.0 : 0.94
        Behavior on opacity { NumberAnimation { duration: 260 } }
        Behavior on scale { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }

        ShaderEffect {
            anchors.fill: parent
            visible: !win.isSoftware
            vertexShader: win.effectVert
            property var srcTex: bgSource
            property vector2d uCard: Qt.vector2d(ccPanel.width, ccPanel.height)
            property real uRadius: 26
            property color uTint: Qt.rgba(0.60, 0.66, 0.82, 0.14 + bridge.glassTint)
            property color uAccent: win.accent
            property real uRefr: bridge.glassRefr
            property real uGlow: 0.2
            fragmentShader: win.glassFrag
        }
        Rectangle {
            anchors.fill: parent
            visible: win.isSoftware
            radius: 26
            color: Qt.rgba(0.09, 0.11, 0.19, 0.93)
        }
        // THE FIX: full-surface catcher so clicks on the panel body, gaps
        // and sliders can never fall through to the outside-click closer
        MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            onClicked: { }
            onWheel: { }
        }

        Flickable {
            anchors.fill: parent
            anchors.margins: 6
            clip: true
            contentHeight: ccCol.height + 20
            interactive: contentHeight > height

            Column {
                id: ccCol
                x: 22
                y: 14
                width: parent.width - 44
                spacing: 14

                Item {
                    width: parent.width
                    height: 34
                    Text {
                        text: "Control Center"
                        color: "#f4f6fb"
                        font.pixelSize: 20
                        font.weight: Font.Bold
                    }
                    Text {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        text: "click outside or Esc to close"
                        color: Qt.rgba(1, 1, 1, 0.35)
                        font.pixelSize: 11
                        font.letterSpacing: 1
                    }
                }

                // ---- theme engine
                Text {
                    text: "ACCENT THEME"
                    color: Qt.rgba(1, 1, 1, 0.45)
                    font.pixelSize: 11
                    font.letterSpacing: 2
                }
                Flow {
                    width: parent.width
                    spacing: 10
                    Repeater {
                        model: ["#e8434f", "#f97316", "#facc15", "#34d399",
                                "#22d3ee", "#3b82f6", "#a78bfa", "#f472b6",
                                "#fb7185", "#4ade80", "#38bdf8", "#c084fc"]
                        Rectangle {
                            width: 32
                            height: 32
                            radius: 16
                            color: modelData
                            border.color:
                                bridge.accent.toLowerCase() === modelData.toLowerCase()
                                ? "#ffffff" : Qt.rgba(1, 1, 1, 0.25)
                            border.width:
                                bridge.accent.toLowerCase() === modelData.toLowerCase()
                                ? 2.5 : 1
                            MouseArea {
                                anchors.fill: parent
                                anchors.margins: -6
                                cursorShape: Qt.PointingHandCursor
                                onClicked: bridge.setAccent(modelData)
                            }
                        }
                    }
                }

                // ---- PiP section
                Column {
                    width: parent.width
                    spacing: 10
                    visible: bridge.pipActive
                    Rectangle { width: parent.width; height: 1; color: Qt.rgba(1, 1, 1, 0.10) }
                    Text {
                        text: "PICTURE-IN-PICTURE · " + bridge.pipAppName
                        color: Qt.rgba(1, 1, 1, 0.45)
                        font.pixelSize: 11
                        font.letterSpacing: 2
                        elide: Text.ElideRight
                        width: parent.width
                    }
                    Row {
                        spacing: 10
                        Repeater {
                            model: [
                                { t: "Fullscreen", a: "full", c: false },
                                { t: "Left", a: "left", c: false },
                                { t: "Right", a: "right", c: false },
                                { t: "Close", a: "close", c: true }
                            ]
                            Rectangle {
                                width: 100
                                height: 40
                                radius: 12
                                color: modelData.c ? "#c0392b" : win.accent
                                opacity: cca.containsMouse ? 0.88 : 1.0
                                Behavior on opacity { NumberAnimation { duration: 120 } }
                                Text {
                                    anchors.centerIn: parent
                                    text: modelData.t
                                    color: "#fff"
                                    font.pixelSize: 13
                                    font.weight: Font.DemiBold
                                }
                                MouseArea {
                                    id: cca
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: bridge.pipAction(modelData.a)
                                }
                            }
                        }
                    }
                }

                // ---- running app section
                Column {
                    width: parent.width
                    spacing: 10
                    visible: bridge.runningIds.length > 0
                    Rectangle { width: parent.width; height: 1; color: Qt.rgba(1, 1, 1, 0.10) }
                    Text {
                        text: "RUNNING APP"
                        color: Qt.rgba(1, 1, 1, 0.45)
                        font.pixelSize: 11
                        font.letterSpacing: 2
                    }
                    Row {
                        spacing: 10
                        Rectangle {
                            width: 150
                            height: 40
                            radius: 12
                            color: win.accent
                            Text {
                                anchors.centerIn: parent
                                text: "Back to App"
                                color: "#fff"
                                font.pixelSize: 13
                                font.weight: Font.DemiBold
                            }
                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: { win.ccOpen = false; bridge.backToApp() }
                            }
                        }
                        Rectangle {
                            width: 130
                            height: 40
                            radius: 12
                            color: Qt.rgba(1, 1, 1, 0.07)
                            border.color: Qt.rgba(1, 1, 1, 0.14)
                            Text {
                                anchors.centerIn: parent
                                text: "Close App"
                                color: "#fff"
                                font.pixelSize: 13
                            }
                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: { bridge.closeApp(bridge.runningIds.length > 0 ? bridge.runningIds[bridge.runningIds.length - 1] : "") }
                            }
                        }
                    }
                }

                Rectangle { width: parent.width; height: 1; color: Qt.rgba(1, 1, 1, 0.10) }

                // ---- volume slider
                Text {
                    text: "VOLUME"
                    color: Qt.rgba(1, 1, 1, 0.45)
                    font.pixelSize: 11
                    font.letterSpacing: 2
                }
                Item {
                    width: parent.width
                    height: 34
                    function setFromX(x) {
                        bridge.setVolume(Math.round(win.clamp(x / volTrack.width, 0, 1) * 100))
                    }
                    Rectangle {
                        id: volTrack
                        width: parent.width - 130
                        height: 8
                        radius: 4
                        anchors.verticalCenter: parent.verticalCenter
                        color: Qt.rgba(1, 1, 1, 0.12)
                        Rectangle {
                            width: volTrack.width * win.clamp(bridge.volume / 100.0, 0, 1)
                            height: parent.height
                            radius: 4
                            color: bridge.muted ? Qt.rgba(1, 1, 1, 0.3) : win.accent
                        }
                        Rectangle {
                            width: 20; height: 20; radius: 10
                            x: volTrack.width * win.clamp(bridge.volume / 100.0, 0, 1) - 10
                            anchors.verticalCenter: parent.verticalCenter
                            color: "#ffffff"
                        }
                        MouseArea {
                            anchors.fill: parent
                            anchors.margins: -12
                            cursorShape: Qt.PointingHandCursor
                            preventStealing: true
                            onPressed: parent.parent.setFromX(mouseX)
                            onPositionChanged: if (pressed) parent.parent.setFromX(mouseX)
                        }
                    }
                    Text {
                        x: volTrack.width + 16
                        width: 70
                        anchors.verticalCenter: parent.verticalCenter
                        text: bridge.muted ? "Muted" : bridge.volume + "%"
                        color: bridge.muted ? Qt.rgba(1, 1, 1, 0.45) : win.accent
                        font.pixelSize: 15
                        font.weight: Font.Bold
                    }
                    Rectangle {
                        x: volTrack.width + 92
                        width: 42
                        height: 30
                        radius: 10
                        anchors.verticalCenter: parent.verticalCenter
                        color: bridge.muted ? win.accent : Qt.rgba(1, 1, 1, 0.07)
                        border.color: Qt.rgba(1, 1, 1, 0.14)
                        Text {
                            anchors.centerIn: parent
                            text: bridge.muted ? "M" : "M"
                            color: "#fff"
                            font.pixelSize: 12
                            font.weight: Font.Bold
                        }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: bridge.volumeMute()
                        }
                    }
                }

                // ---- brightness slider
                Text {
                    text: "BRIGHTNESS"
                    color: Qt.rgba(1, 1, 1, 0.45)
                    font.pixelSize: 11
                    font.letterSpacing: 2
                }
                Item {
                    width: parent.width
                    height: 34
                    function setFromX(x) {
                        bridge.setBrightness(Math.round(win.clamp(x / briTrack.width, 0, 1) * 100))
                    }
                    Rectangle {
                        id: briTrack
                        width: parent.width - 130
                        height: 8
                        radius: 4
                        anchors.verticalCenter: parent.verticalCenter
                        color: Qt.rgba(1, 1, 1, 0.12)
                        Rectangle {
                            width: briTrack.width * win.clamp(bridge.brightness / 100.0, 0, 1)
                            height: parent.height
                            radius: 4
                            color: win.accent
                        }
                        Rectangle {
                            width: 20; height: 20; radius: 10
                            x: briTrack.width * win.clamp(bridge.brightness / 100.0, 0, 1) - 10
                            anchors.verticalCenter: parent.verticalCenter
                            color: "#ffffff"
                        }
                        MouseArea {
                            anchors.fill: parent
                            anchors.margins: -12
                            cursorShape: Qt.PointingHandCursor
                            preventStealing: true
                            onPressed: parent.parent.setFromX(mouseX)
                            onPositionChanged: if (pressed) parent.parent.setFromX(mouseX)
                        }
                    }
                    Text {
                        x: briTrack.width + 16
                        anchors.verticalCenter: parent.verticalCenter
                        text: bridge.brightness + "%"
                        color: win.accent
                        font.pixelSize: 15
                        font.weight: Font.Bold
                    }
                }

                Rectangle { width: parent.width; height: 1; color: Qt.rgba(1, 1, 1, 0.10) }

                // ---- power
                Text {
                    text: "POWER & SESSION"
                    color: Qt.rgba(1, 1, 1, 0.45)
                    font.pixelSize: 11
                    font.letterSpacing: 2
                }
                Flow {
                    width: parent.width
                    spacing: 10
                    Repeater {
                        model: [
                            { t: "Sleep", a: "suspend", arm: false, red: false },
                            { t: "Restart", a: "reboot", arm: true, red: false },
                            { t: "Shut Down", a: "poweroff", arm: true, red: true },
                            { t: "Log Out", a: "logout", arm: true, red: false }
                        ]
                        Rectangle {
                            width: 102
                            height: 40
                            radius: 12
                            property bool armed: false
                            color: armed ? (modelData.red ? "#c0392b" : win.accent)
                                         : Qt.rgba(1, 1, 1, 0.07)
                            border.color: Qt.rgba(1, 1, 1, 0.14)
                            Timer {
                                id: disarm
                                interval: 3000
                                onTriggered: parent.armed = false
                            }
                            Text {
                                anchors.centerIn: parent
                                text: parent.armed ? "Confirm?" : modelData.t
                                color: "#fff"
                                font.pixelSize: 13
                            }
                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    if (!modelData.arm) {
                                        bridge.powerAction(modelData.a)
                                    } else if (parent.armed) {
                                        parent.armed = false
                                        if (modelData.a === "logout") bridge.logout()
                                        else bridge.powerAction(modelData.a)
                                    } else {
                                        parent.armed = true
                                        disarm.restart()
                                    }
                                }
                            }
                        }
                    }
                }

                Rectangle { width: parent.width; height: 1; color: Qt.rgba(1, 1, 1, 0.10) }

                Row {
                    spacing: 10
                    Rectangle {
                        width: 170
                        height: 44
                        radius: 12
                        color: win.accent
                        Text {
                            anchors.centerIn: parent
                            text: "All Settings"
                            color: "#fff"
                            font.pixelSize: 14
                            font.weight: Font.DemiBold
                        }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: { win.ccOpen = false; win.settingsOpen = true }
                        }
                    }
                    Rectangle {
                        width: 150
                        height: 44
                        radius: 12
                        color: Qt.rgba(1, 1, 1, 0.07)
                        border.color: Qt.rgba(1, 1, 1, 0.14)
                        Text {
                            anchors.centerIn: parent
                            text: "Rescan Apps"
                            color: "#fff"
                            font.pixelSize: 14
                        }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: bridge.rescan()
                        }
                    }
                }
            }
        }
    }

    // ============================== SETTINGS APP (TV UI) =====================
    Item {
        id: settingsRoot
        objectName: "settingsRoot"
        z: 10
        anchors.fill: parent
        visible: opacity > 0.01
        opacity: win.settingsOpen ? 1.0 : 0.0
        enabled: win.settingsOpen
        Behavior on opacity { NumberAnimation { duration: 220 } }

        property int secIndex: 0
        property var sections: ["Appearance", "Display", "Sound", "Network",
                                "Bluetooth", "Mouse & Keys", "Power", "About"]
        onVisibleChanged: {
            if (visible) {
                bridge.refreshRes()
                bridge.refreshSinks()
                bridge.refreshWifi()
                bridge.refreshBt()
                bridge.refreshSysInfo()
            }
        }

        Rectangle { anchors.fill: parent; color: Qt.rgba(0, 0, 0, 0.55) }
        MouseArea { anchors.fill: parent; onClicked: { } }

        Item {
            id: setPanel
            anchors.fill: parent
            anchors.margins: 44

            ShaderEffect {
                anchors.fill: parent
                visible: !win.isSoftware
                vertexShader: win.effectVert
                property var srcTex: bgSource
                property vector2d uCard: Qt.vector2d(setPanel.width, setPanel.height)
                property real uRadius: 30
                property color uTint: Qt.rgba(0.60, 0.66, 0.82, 0.14 + bridge.glassTint)
                property color uAccent: win.accent
                property real uRefr: bridge.glassRefr
                property real uGlow: 0.15
                fragmentShader: win.glassFrag
            }
            Rectangle {
                anchors.fill: parent
                visible: win.isSoftware
                radius: 30
                color: Qt.rgba(0.08, 0.10, 0.18, 0.96)
            }
            MouseArea { anchors.fill: parent; onClicked: { } }

            // header
            Item {
                id: setHeader
                x: 26
                y: 20
                width: parent.width - 52
                height: 46
                Text {
                    text: "Aura Settings"
                    color: "#f4f6fb"
                    font.pixelSize: 24
                    font.weight: Font.Bold
                }
                Text {
                    anchors.left: parent.left
                    anchors.leftMargin: 190
                    anchors.verticalCenter: parent.verticalCenter
                    text: "your TV settings hub - replaces the desktop control panel"
                    color: Qt.rgba(1, 1, 1, 0.35)
                    font.pixelSize: 12
                    font.letterSpacing: 1
                }
                Rectangle {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    width: 92
                    height: 38
                    radius: 12
                    color: win.accent
                    Text {
                        anchors.centerIn: parent
                        text: "Done"
                        color: "#fff"
                        font.pixelSize: 14
                        font.weight: Font.DemiBold
                    }
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: win.settingsOpen = false
                    }
                }
            }

            // left rail
            Column {
                id: rail
                x: 26
                y: 84
                width: 190
                spacing: 6
                Repeater {
                    model: settingsRoot.sections
                    Rectangle {
                        width: rail.width
                        height: 46
                        radius: 12
                        color: settingsRoot.secIndex === index
                               ? win.accent : Qt.rgba(1, 1, 1, 0.05)
                        opacity: settingsRoot.secIndex === index ? 1.0 : 0.75
                        Behavior on color { ColorAnimation { duration: 160 } }
                        Row {
                            x: 12
                            spacing: 10
                            anchors.verticalCenter: parent.verticalCenter
                            Rectangle {
                                width: 26; height: 26; radius: 13
                                color: settingsRoot.secIndex === index
                                       ? Qt.rgba(1, 1, 1, 0.25) : win.accent
                                Text {
                                    anchors.centerIn: parent
                                    text: modelData.substring(0, 1)
                                    color: "#fff"
                                    font.pixelSize: 13
                                    font.weight: Font.Bold
                                }
                            }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: modelData
                                color: "#f4f6fb"
                                font.pixelSize: 14
                                font.weight: settingsRoot.secIndex === index
                                             ? Font.DemiBold : Font.Normal
                            }
                        }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: settingsRoot.secIndex = index
                        }
                    }
                }
            }

            // content loader
            Loader {
                id: secLoader
                x: 232
                y: 84
                width: parent.width - 258
                height: parent.height - 104
                sourceComponent: [appearanceC, displayC, soundC, netC,
                                  btC, mouseC, powerC, aboutC][settingsRoot.secIndex]
            }

            // ---------------- section: Appearance ---------------------------
            Component {
                id: appearanceC
                Flickable {
                    clip: true
                    contentHeight: aCol.height + 24
                    Column {
                        id: aCol
                        width: parent.width
                        spacing: 10
                        Text { text: "ACCENT THEME"; color: Qt.rgba(1,1,1,0.45); font.pixelSize: 11; font.letterSpacing: 2 }
                        Flow {
                            width: parent.width
                            spacing: 10
                            Repeater {
                                model: ["#e8434f", "#f97316", "#facc15", "#34d399",
                                        "#22d3ee", "#3b82f6", "#a78bfa", "#f472b6",
                                        "#fb7185", "#4ade80", "#38bdf8", "#c084fc"]
                                Rectangle {
                                    width: 36; height: 36; radius: 18
                                    color: modelData
                                    border.color:
                                        bridge.accent.toLowerCase() === modelData.toLowerCase()
                                        ? "#ffffff" : Qt.rgba(1, 1, 1, 0.25)
                                    border.width:
                                        bridge.accent.toLowerCase() === modelData.toLowerCase()
                                        ? 3 : 1
                                    MouseArea {
                                        anchors.fill: parent
                                        anchors.margins: -6
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: bridge.setAccent(modelData)
                                    }
                                }
                            }
                        }
                        Rectangle { width: parent.width; height: 1; color: Qt.rgba(1, 1, 1, 0.08) }

                        // wave intensity
                        Text { text: "WAVE BACKGROUND"; color: Qt.rgba(1,1,1,0.45); font.pixelSize: 11; font.letterSpacing: 2 }
                        Column {
                            width: parent.width
                            spacing: 8
                            Repeater {
                                model: [
                                    { t: "Wave intensity", v: bridge.waveIntensity, min: 0.1, max: 2.0, f: 100 },
                                    { t: "Wave speed", v: bridge.waveSpeed, min: 0.1, max: 3.0, f: 100 }
                                ]
                                Item {
                                    width: aCol.width
                                    height: 34
                                    Text {
                                        text: modelData.t
                                        color: "#f4f6fb"
                                        font.pixelSize: 14
                                        anchors.verticalCenter: parent.verticalCenter
                                    }
                                    Text {
                                        x: 200
                                        text: Math.round(modelData.v * modelData.f) + "%"
                                        color: win.accent
                                        font.pixelSize: 14
                                        font.weight: Font.Bold
                                        anchors.verticalCenter: parent.verticalCenter
                                    }
                                    Rectangle {
                                        id: wTrack
                                        x: 260
                                        width: parent.width - 260
                                        height: 8
                                        radius: 4
                                        anchors.verticalCenter: parent.verticalCenter
                                        color: Qt.rgba(1, 1, 1, 0.12)
                                        Rectangle {
                                            width: wTrack.width * win.clamp(modelData.v, 0.1, modelData.max) / modelData.max
                                            height: parent.height
                                            radius: 4
                                            color: win.accent
                                        }
                                        Rectangle {
                                            width: 18; height: 18; radius: 9
                                            x: wTrack.width * win.clamp(modelData.v, 0.1, modelData.max) / modelData.max - 9
                                            anchors.verticalCenter: parent.verticalCenter
                                            color: "#ffffff"
                                        }
                                        MouseArea {
                                            anchors.fill: parent
                                            anchors.margins: -12
                                            cursorShape: Qt.PointingHandCursor
                                            preventStealing: true
                                            onPressed: {
                                                var v = win.clamp(mouseX / wTrack.width, 0, 1) * modelData.max
                                                if (modelData.f === 100 && modelData.t === "Wave intensity") bridge.setWaveIntensity(v)
                                                else bridge.setWaveSpeed(v)
                                            }
                                            onPositionChanged: if (pressed) {
                                                var v = win.clamp(mouseX / wTrack.width, 0, 1) * modelData.max
                                                if (modelData.t === "Wave intensity") bridge.setWaveIntensity(v)
                                                else bridge.setWaveSpeed(v)
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        // glass tuning
                        Text { text: "GLASS"; color: Qt.rgba(1,1,1,0.45); font.pixelSize: 11; font.letterSpacing: 2 }
                        Column {
                            width: parent.width
                            spacing: 8
                            Repeater {
                                model: [
                                    { t: "Refraction bend", v: bridge.glassRefr, max: 0.05, d: 1000 },
                                    { t: "Glass tint", v: bridge.glassTint, max: 0.6, d: 100 }
                                ]
                                Item {
                                    width: aCol.width
                                    height: 34
                                    property bool isRefr: modelData.t === "Refraction bend"
                                    Text {
                                        text: modelData.t
                                        color: "#f4f6fb"
                                        font.pixelSize: 14
                                        anchors.verticalCenter: parent.verticalCenter
                                    }
                                    Text {
                                        x: 200
                                        text: Math.round(modelData.v * (parent.isRefr ? 1000 : 100)) + (parent.isRefr ? "‰" : "%")
                                        color: win.accent
                                        font.pixelSize: 14
                                        font.weight: Font.Bold
                                        anchors.verticalCenter: parent.verticalCenter
                                    }
                                    Rectangle {
                                        id: gTrack
                                        x: 260
                                        width: parent.width - 260
                                        height: 8
                                        radius: 4
                                        anchors.verticalCenter: parent.verticalCenter
                                        color: Qt.rgba(1, 1, 1, 0.12)
                                        Rectangle {
                                            width: gTrack.width * win.clamp(modelData.v, 0, modelData.max) / modelData.max
                                            height: parent.height
                                            radius: 4
                                            color: win.accent
                                        }
                                        Rectangle {
                                            width: 18; height: 18; radius: 9
                                            x: gTrack.width * win.clamp(modelData.v, 0, modelData.max) / modelData.max - 9
                                            anchors.verticalCenter: parent.verticalCenter
                                            color: "#ffffff"
                                        }
                                        MouseArea {
                                            anchors.fill: parent
                                            anchors.margins: -12
                                            cursorShape: Qt.PointingHandCursor
                                            preventStealing: true
                                            onPressed: {
                                                var v = win.clamp(mouseX / gTrack.width, 0, 1) * modelData.max
                                                if (parent.isRefr) bridge.setGlassRefr(v); else bridge.setGlassTint(v)
                                            }
                                            onPositionChanged: if (pressed) {
                                                var v = win.clamp(mouseX / gTrack.width, 0, 1) * modelData.max
                                                if (parent.isRefr) bridge.setGlassRefr(v); else bridge.setGlassTint(v)
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        // icon size
                        Text { text: "ICON SIZE"; color: Qt.rgba(1,1,1,0.45); font.pixelSize: 11; font.letterSpacing: 2 }
                        Row {
                            spacing: 10
                            Repeater {
                                model: [{ t: "Small", v: 0.85 }, { t: "Medium", v: 1.0 }, { t: "Large", v: 1.2 }]
                                Rectangle {
                                    width: 110; height: 40; radius: 12
                                    color: Math.abs(bridge.iconScale - modelData.v) < 0.01
                                           ? win.accent : Qt.rgba(1, 1, 1, 0.07)
                                    border.color: Qt.rgba(1, 1, 1, 0.14)
                                    Text { anchors.centerIn: parent; text: modelData.t; color: "#fff"; font.pixelSize: 13 }
                                    MouseArea {
                                        anchors.fill: parent
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: bridge.setIconScale(modelData.v)
                                    }
                                }
                            }
                        }

                        Rectangle { width: parent.width; height: 1; color: Qt.rgba(1, 1, 1, 0.08) }
                        Text { text: "CLOCK & WEATHER"; color: Qt.rgba(1,1,1,0.45); font.pixelSize: 11; font.letterSpacing: 2 }

                        // toggles
                        Repeater {
                            model: [
                                { t: "24-hour clock", v: bridge.clock24, s: "setClock24" },
                                { t: "Show seconds", v: bridge.showSeconds, s: "setShowSeconds" }
                            ]
                            Rectangle {
                                width: aCol.width
                                height: 50
                                radius: 12
                                color: Qt.rgba(1, 1, 1, 0.05)
                                Text {
                                    x: 14
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: modelData.t
                                    color: "#f4f6fb"
                                    font.pixelSize: 14
                                }
                                Item {
                                    anchors.right: parent.right
                                    anchors.rightMargin: 14
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 46; height: 24
                                    Rectangle {
                                        anchors.fill: parent
                                        radius: 12
                                        color: modelData.v ? win.accent : Qt.rgba(1, 1, 1, 0.15)
                                        Behavior on color { ColorAnimation { duration: 150 } }
                                    }
                                    Rectangle {
                                        x: modelData.v ? 24 : 2
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: 20; height: 20; radius: 10
                                        color: "#fff"
                                        Behavior on x { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
                                    }
                                    MouseArea {
                                        anchors.fill: parent
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            if (modelData.s === "setClock24") bridge.setClock24(!modelData.v)
                                            else bridge.setShowSeconds(!modelData.v)
                                        }
                                    }
                                }
                            }
                        }

                        Rectangle {
                            width: aCol.width
                            height: 50
                            radius: 12
                            color: Qt.rgba(1, 1, 1, 0.05)
                            Text {
                                x: 14
                                anchors.verticalCenter: parent.verticalCenter
                                text: "Weather city (empty = auto)"
                                color: "#f4f6fb"
                                font.pixelSize: 14
                            }
                            Rectangle {
                                anchors.right: parent.right
                                anchors.rightMargin: 14
                                anchors.verticalCenter: parent.verticalCenter
                                width: 180; height: 32; radius: 8
                                color: Qt.rgba(1, 1, 1, 0.08)
                                border.color: cityInput.activeFocus ? win.accent : Qt.rgba(1, 1, 1, 0.15)
                                TextInput {
                                    id: cityInput
                                    anchors.fill: parent
                                    anchors.margins: 7
                                    color: "#f4f6fb"
                                    font.pixelSize: 13
                                    clip: true
                                    text: bridge.city
                                    onEditingFinished: bridge.setCity(text)
                                }
                            }
                        }
                    }
                }
            }

            // ---------------- section: Display -------------------------------
            Component {
                id: displayC
                Flickable {
                    clip: true
                    contentHeight: dCol.height + 24
                    Column {
                        id: dCol
                        width: parent.width
                        spacing: 10
                        Text { text: "RESOLUTION"; color: Qt.rgba(1,1,1,0.45); font.pixelSize: 11; font.letterSpacing: 2 }
                        Column {
                            width: parent.width
                            spacing: 6
                            Repeater {
                                model: bridge.resList
                                Rectangle {
                                    width: dCol.width
                                    height: 48
                                    radius: 12
                                    color: modelData.current
                                           ? Qt.rgba(1, 1, 1, 0.10) : Qt.rgba(1, 1, 1, 0.05)
                                    Text {
                                        x: 14
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: modelData.mode + "   ·   " + modelData.rate + " Hz"
                                        color: modelData.current ? win.accent : "#f4f6fb"
                                        font.pixelSize: 14
                                        font.weight: modelData.current ? Font.DemiBold : Font.Normal
                                    }
                                    Rectangle {
                                        anchors.right: parent.right
                                        anchors.rightMargin: 14
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: 18; height: 18; radius: 9
                                        color: "transparent"
                                        border.color: modelData.current ? win.accent : Qt.rgba(1, 1, 1, 0.3)
                                        border.width: 2
                                        Rectangle {
                                            anchors.centerIn: parent
                                            width: 8; height: 8; radius: 4
                                            color: win.accent
                                            visible: modelData.current
                                        }
                                    }
                                    MouseArea {
                                        anchors.fill: parent
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: if (!modelData.current) bridge.setRes(modelData.mode, modelData.rate)
                                    }
                                }
                            }
                            Text {
                                visible: bridge.resList.length === 0
                                text: "No modes reported (xrandr unavailable)"
                                color: Qt.rgba(1, 1, 1, 0.35)
                                font.pixelSize: 13
                            }
                        }

                        Rectangle { width: parent.width; height: 1; color: Qt.rgba(1, 1, 1, 0.08) }
                        Text { text: "NIGHT MODE"; color: Qt.rgba(1,1,1,0.45); font.pixelSize: 11; font.letterSpacing: 2 }
                        Rectangle {
                            width: dCol.width
                            height: 50
                            radius: 12
                            color: Qt.rgba(1, 1, 1, 0.05)
                            Column {
                                x: 14
                                spacing: 2
                                anchors.verticalCenter: parent.verticalCenter
                                Text { text: "Warm screen (evening viewing)"; color: "#f4f6fb"; font.pixelSize: 14 }
                                Text { text: "Shifts colours via xrandr gamma"; color: Qt.rgba(1, 1, 1, 0.35); font.pixelSize: 11 }
                            }
                            Item {
                                anchors.right: parent.right
                                anchors.rightMargin: 14
                                anchors.verticalCenter: parent.verticalCenter
                                width: 46; height: 24
                                Rectangle {
                                    anchors.fill: parent
                                    radius: 12
                                    color: bridge.nightMode ? win.accent : Qt.rgba(1, 1, 1, 0.15)
                                }
                                Rectangle {
                                    x: bridge.nightMode ? 24 : 2
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 20; height: 20; radius: 10
                                    color: "#fff"
                                    Behavior on x { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: bridge.setNight(!bridge.nightMode)
                                }
                            }
                        }

                        Text { text: "BRIGHTNESS"; color: Qt.rgba(1,1,1,0.45); font.pixelSize: 11; font.letterSpacing: 2 }
                        Item {
                            width: dCol.width
                            height: 34
                            function setFromX(x) {
                                bridge.setBrightness(Math.round(win.clamp(x / dbTrack.width, 0, 1) * 100))
                            }
                            Text { text: "Backlight"; color: "#f4f6fb"; font.pixelSize: 14; anchors.verticalCenter: parent.verticalCenter }
                            Rectangle {
                                id: dbTrack
                                x: 260
                                width: parent.width - 340
                                height: 8
                                radius: 4
                                anchors.verticalCenter: parent.verticalCenter
                                color: Qt.rgba(1, 1, 1, 0.12)
                                Rectangle {
                                    width: dbTrack.width * win.clamp(bridge.brightness / 100.0, 0, 1)
                                    height: parent.height
                                    radius: 4
                                    color: win.accent
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    anchors.margins: -12
                                    cursorShape: Qt.PointingHandCursor
                                    preventStealing: true
                                    onPressed: parent.parent.setFromX(mouseX)
                                    onPositionChanged: if (pressed) parent.parent.setFromX(mouseX)
                                }
                            }
                            Text {
                                anchors.right: parent.right
                                text: bridge.brightness + "%"
                                color: win.accent
                                font.pixelSize: 14
                                font.weight: Font.Bold
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }

                        Text { text: "SCREEN BLANK TIMER"; color: Qt.rgba(1,1,1,0.45); font.pixelSize: 11; font.letterSpacing: 2 }
                        Row {
                            spacing: 10
                            Repeater {
                                model: [{ t: "Never", v: 0 }, { t: "1 min", v: 1 }, { t: "5 min", v: 5 }, { t: "10 min", v: 10 }, { t: "15 min", v: 15 }]
                                Rectangle {
                                    width: 96; height: 40; radius: 12
                                    color: bridge.blankMin === modelData.v
                                           ? win.accent : Qt.rgba(1, 1, 1, 0.07)
                                    border.color: Qt.rgba(1, 1, 1, 0.14)
                                    Text { anchors.centerIn: parent; text: modelData.t; color: "#fff"; font.pixelSize: 13 }
                                    MouseArea {
                                        anchors.fill: parent
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: bridge.setBlank(modelData.v)
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // ---------------- section: Sound ---------------------------------
            Component {
                id: soundC
                Flickable {
                    clip: true
                    contentHeight: sCol.height + 24
                    Column {
                        id: sCol
                        width: parent.width
                        spacing: 10
                        Text { text: "MASTER VOLUME"; color: Qt.rgba(1,1,1,0.45); font.pixelSize: 11; font.letterSpacing: 2 }
                        Item {
                            width: sCol.width
                            height: 40
                            function setFromX(x) {
                                bridge.setVolume(Math.round(win.clamp(x / svTrack.width, 0, 1) * 100))
                            }
                            Rectangle {
                                id: svTrack
                                width: parent.width - 120
                                height: 10
                                radius: 5
                                anchors.verticalCenter: parent.verticalCenter
                                color: Qt.rgba(1, 1, 1, 0.12)
                                Rectangle {
                                    width: svTrack.width * win.clamp(bridge.volume / 100.0, 0, 1)
                                    height: parent.height
                                    radius: 5
                                    color: bridge.muted ? Qt.rgba(1, 1, 1, 0.3) : win.accent
                                }
                                Rectangle {
                                    width: 22; height: 22; radius: 11
                                    x: svTrack.width * win.clamp(bridge.volume / 100.0, 0, 1) - 11
                                    anchors.verticalCenter: parent.verticalCenter
                                    color: "#fff"
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    anchors.margins: -12
                                    cursorShape: Qt.PointingHandCursor
                                    preventStealing: true
                                    onPressed: parent.parent.setFromX(mouseX)
                                    onPositionChanged: if (pressed) parent.parent.setFromX(mouseX)
                                }
                            }
                            Text {
                                x: svTrack.width + 16
                                width: 60
                                anchors.verticalCenter: parent.verticalCenter
                                text: bridge.muted ? "Muted" : bridge.volume + "%"
                                color: bridge.muted ? Qt.rgba(1, 1, 1, 0.45) : win.accent
                                font.pixelSize: 15
                                font.weight: Font.Bold
                            }
                            Rectangle {
                                anchors.right: parent.right
                                width: 90; height: 38; radius: 12
                                anchors.verticalCenter: parent.verticalCenter
                                color: bridge.muted ? win.accent : Qt.rgba(1, 1, 1, 0.07)
                                border.color: Qt.rgba(1, 1, 1, 0.14)
                                Text { anchors.centerIn: parent; text: bridge.muted ? "Unmute" : "Mute"; color: "#fff"; font.pixelSize: 13 }
                                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: bridge.volumeMute() }
                            }
                        }

                        Rectangle { width: parent.width; height: 1; color: Qt.rgba(1, 1, 1, 0.08) }
                        Text { text: "OUTPUT DEVICE"; color: Qt.rgba(1,1,1,0.45); font.pixelSize: 11; font.letterSpacing: 2 }
                        Column {
                            width: parent.width
                            spacing: 6
                            Repeater {
                                model: bridge.sinks
                                Rectangle {
                                    width: sCol.width
                                    height: 48
                                    radius: 12
                                    color: bridge.curSink === modelData.name
                                           ? Qt.rgba(1, 1, 1, 0.10) : Qt.rgba(1, 1, 1, 0.05)
                                    Text {
                                        x: 14
                                        width: parent.width - 60
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: modelData.desc
                                        color: bridge.curSink === modelData.name ? win.accent : "#f4f6fb"
                                        font.pixelSize: 13
                                        elide: Text.ElideRight
                                    }
                                    Rectangle {
                                        anchors.right: parent.right
                                        anchors.rightMargin: 14
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: 18; height: 18; radius: 9
                                        color: "transparent"
                                        border.color: bridge.curSink === modelData.name ? win.accent : Qt.rgba(1, 1, 1, 0.3)
                                        border.width: 2
                                        Rectangle {
                                            anchors.centerIn: parent
                                            width: 8; height: 8; radius: 4
                                            color: win.accent
                                            visible: bridge.curSink === modelData.name
                                        }
                                    }
                                    MouseArea {
                                        anchors.fill: parent
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: if (bridge.curSink !== modelData.name) bridge.setSink(modelData.name)
                                    }
                                }
                            }
                            Text {
                                visible: bridge.sinks.length === 0
                                text: "No sinks found (pactl unavailable)"
                                color: Qt.rgba(1, 1, 1, 0.35)
                                font.pixelSize: 13
                            }
                        }
                    }
                }
            }

            // ---------------- section: Network -------------------------------
            Component {
                id: netC
                Flickable {
                    clip: true
                    contentHeight: nCol.height + 24
                    Column {
                        id: nCol
                        width: parent.width
                        spacing: 10
                        Item {
                            width: nCol.width
                            height: 50
                            Rectangle {
                                width: parent.width; height: 50; radius: 12
                                color: Qt.rgba(1, 1, 1, 0.05)
                            }
                            Column {
                                x: 14
                                spacing: 2
                                anchors.verticalCenter: parent.verticalCenter
                                Text { text: "Wi-Fi"; color: "#f4f6fb"; font.pixelSize: 14 }
                                Text { text: bridge.wifiEnabled ? "Enabled" : "Disabled"; color: Qt.rgba(1, 1, 1, 0.35); font.pixelSize: 11 }
                            }
                            Item {
                                anchors.right: parent.right
                                anchors.rightMargin: 14
                                anchors.verticalCenter: parent.verticalCenter
                                width: 46; height: 24
                                Rectangle {
                                    anchors.fill: parent
                                    radius: 12
                                    color: bridge.wifiEnabled ? win.accent : Qt.rgba(1, 1, 1, 0.15)
                                }
                                Rectangle {
                                    x: bridge.wifiEnabled ? 24 : 2
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 20; height: 20; radius: 10
                                    color: "#fff"
                                    Behavior on x { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: bridge.wifiToggle(!bridge.wifiEnabled)
                                }
                            }
                        }
                        Rectangle {
                            width: nCol.width
                            height: 50
                            radius: 12
                            color: Qt.rgba(1, 1, 1, 0.05)
                            Column {
                                x: 14
                                spacing: 2
                                anchors.verticalCenter: parent.verticalCenter
                                Text { text: "Current network"; color: "#f4f6fb"; font.pixelSize: 14 }
                                Text {
                                    text: bridge.curSsid === "" ? "Not connected" : bridge.curSsid
                                    color: bridge.curSsid === "" ? Qt.rgba(1, 1, 1, 0.35) : win.accent
                                    font.pixelSize: 12
                                }
                            }
                            Rectangle {
                                anchors.right: parent.right
                                anchors.rightMargin: 14
                                anchors.verticalCenter: parent.verticalCenter
                                visible: bridge.curSsid !== ""
                                width: 110; height: 34; radius: 10
                                color: Qt.rgba(1, 1, 1, 0.08)
                                border.color: Qt.rgba(1, 1, 1, 0.14)
                                Text { anchors.centerIn: parent; text: "Disconnect"; color: "#fff"; font.pixelSize: 12 }
                                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: bridge.wifiDisconnect() }
                            }
                        }

                        Row {
                            spacing: 10
                            Rectangle {
                                width: 120; height: 38; radius: 12
                                color: win.accent
                                Text { anchors.centerIn: parent; text: "Refresh"; color: "#fff"; font.pixelSize: 13; font.weight: Font.DemiBold }
                                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: bridge.refreshWifi() }
                            }
                            Rectangle {
                                width: 150; height: 38; radius: 12
                                color: Qt.rgba(1, 1, 1, 0.07)
                                border.color: Qt.rgba(1, 1, 1, 0.14)
                                Text { anchors.centerIn: parent; text: "Airplane mode"; color: "#fff"; font.pixelSize: 13 }
                                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: bridge.setAirplane(true) }
                            }
                        }

                        Text { text: "AVAILABLE NETWORKS"; color: Qt.rgba(1,1,1,0.45); font.pixelSize: 11; font.letterSpacing: 2 }
                        Column {
                            width: parent.width
                            spacing: 6
                            Repeater {
                                model: bridge.wifiList
                                Rectangle {
                                    width: nCol.width
                                    height: 48
                                    radius: 12
                                    color: modelData.active
                                           ? Qt.rgba(1, 1, 1, 0.10) : Qt.rgba(1, 1, 1, 0.05)
                                    Text {
                                        x: 14
                                        width: parent.width - 190
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: (modelData.secured ? "LOCK  " : "") + modelData.ssid
                                        color: modelData.active ? win.accent : "#f4f6fb"
                                        font.pixelSize: 14
                                        elide: Text.ElideRight
                                    }
                                    Text {
                                        anchors.right: parent.right
                                        anchors.rightMargin: 14
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: modelData.signal + "%"
                                        color: Qt.rgba(1, 1, 1, 0.45)
                                        font.pixelSize: 12
                                    }
                                    MouseArea {
                                        anchors.fill: parent
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            if (modelData.active) return
                                            if (modelData.secured) {
                                                win.pwTargetSsid = modelData.ssid
                                                win.pwOpen = true
                                            } else {
                                                bridge.connectWifi(modelData.ssid, "")
                                            }
                                        }
                                    }
                                }
                            }
                            Text {
                                visible: bridge.wifiList.length === 0
                                text: bridge.wifiEnabled
                                      ? "Scanning... press Refresh"
                                      : "Wi-Fi is off"
                                color: Qt.rgba(1, 1, 1, 0.35)
                                font.pixelSize: 13
                            }
                        }
                    }
                }
            }

            // ---------------- section: Bluetooth -----------------------------
            Component {
                id: btC
                Flickable {
                    clip: true
                    contentHeight: bCol.height + 24
                    Column {
                        id: bCol
                        width: parent.width
                        spacing: 10
                        Rectangle {
                            width: bCol.width
                            height: 50
                            radius: 12
                            color: Qt.rgba(1, 1, 1, 0.05)
                            Column {
                                x: 14
                                spacing: 2
                                anchors.verticalCenter: parent.verticalCenter
                                Text { text: "Bluetooth"; color: "#f4f6fb"; font.pixelSize: 14 }
                                Text { text: bridge.btPowered ? "Powered on" : "Powered off"; color: Qt.rgba(1, 1, 1, 0.35); font.pixelSize: 11 }
                            }
                            Item {
                                anchors.right: parent.right
                                anchors.rightMargin: 14
                                anchors.verticalCenter: parent.verticalCenter
                                width: 46; height: 24
                                Rectangle {
                                    anchors.fill: parent
                                    radius: 12
                                    color: bridge.btPowered ? win.accent : Qt.rgba(1, 1, 1, 0.15)
                                }
                                Rectangle {
                                    x: bridge.btPowered ? 24 : 2
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 20; height: 20; radius: 10
                                    color: "#fff"
                                    Behavior on x { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: bridge.btToggle(!bridge.btPowered)
                                }
                            }
                        }
                        Row {
                            spacing: 10
                            Rectangle {
                                width: 120; height: 38; radius: 12
                                color: win.accent
                                Text { anchors.centerIn: parent; text: "Refresh"; color: "#fff"; font.pixelSize: 13; font.weight: Font.DemiBold }
                                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: bridge.refreshBt() }
                            }
                            Rectangle {
                                width: 150; height: 38; radius: 12
                                color: Qt.rgba(1, 1, 1, 0.07)
                                border.color: Qt.rgba(1, 1, 1, 0.14)
                                Text { anchors.centerIn: parent; text: "Scan for devices"; color: "#fff"; font.pixelSize: 13 }
                                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: bridge.btScan() }
                            }
                        }
                        Column {
                            width: parent.width
                            spacing: 6
                            Repeater {
                                model: bridge.btDevices
                                Rectangle {
                                    width: bCol.width
                                    height: 48
                                    radius: 12
                                    color: modelData.connected
                                           ? Qt.rgba(1, 1, 1, 0.10) : Qt.rgba(1, 1, 1, 0.05)
                                    Text {
                                        x: 14
                                        width: parent.width - 130
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: modelData.name
                                        color: modelData.connected ? win.accent : "#f4f6fb"
                                        font.pixelSize: 14
                                        elide: Text.ElideRight
                                    }
                                    Text {
                                        anchors.right: parent.right
                                        anchors.rightMargin: 14
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: modelData.connected ? "Connected - tap to disconnect"
                                                                  : "Tap to connect"
                                        color: Qt.rgba(1, 1, 1, 0.45)
                                        font.pixelSize: 11
                                    }
                                    MouseArea {
                                        anchors.fill: parent
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            if (modelData.connected) bridge.btDisconnect(modelData.mac)
                                            else bridge.btConnect(modelData.mac)
                                        }
                                    }
                                }
                            }
                            Text {
                                visible: bridge.btDevices.length === 0
                                text: bridge.btPowered
                                      ? "No paired devices - press Scan"
                                      : "Bluetooth is off"
                                color: Qt.rgba(1, 1, 1, 0.35)
                                font.pixelSize: 13
                            }
                        }
                    }
                }
            }

            // ---------------- section: Mouse & Keys --------------------------
            Component {
                id: mouseC
                Flickable {
                    clip: true
                    contentHeight: mCol.height + 24
                    Column {
                        id: mCol
                        width: parent.width
                        spacing: 10
                        Rectangle {
                            width: mCol.width
                            height: 50
                            radius: 12
                            color: Qt.rgba(1, 1, 1, 0.05)
                            Text {
                                x: 14
                                anchors.verticalCenter: parent.verticalCenter
                                text: "Auto-hide cursor"
                                color: "#f4f6fb"
                                font.pixelSize: 14
                            }
                            Item {
                                anchors.right: parent.right
                                anchors.rightMargin: 14
                                anchors.verticalCenter: parent.verticalCenter
                                width: 46; height: 24
                                Rectangle {
                                    anchors.fill: parent
                                    radius: 12
                                    color: bridge.cursorAutohide ? win.accent : Qt.rgba(1, 1, 1, 0.15)
                                }
                                Rectangle {
                                    x: bridge.cursorAutohide ? 24 : 2
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 20; height: 20; radius: 10
                                    color: "#fff"
                                    Behavior on x { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: bridge.setCursorAutohide(!bridge.cursorAutohide)
                                }
                            }
                        }
                        Item {
                            width: mCol.width
                            height: 34
                            function setFromX(x) {
                                bridge.setCursorDelay(Math.max(1, Math.round(win.clamp(x / mdTrack.width, 0, 1) * 15)))
                            }
                            Text { text: "Hide delay"; color: "#f4f6fb"; font.pixelSize: 14; anchors.verticalCenter: parent.verticalCenter }
                            Rectangle {
                                id: mdTrack
                                x: 260
                                width: parent.width - 340
                                height: 8
                                radius: 4
                                anchors.verticalCenter: parent.verticalCenter
                                color: Qt.rgba(1, 1, 1, 0.12)
                                Rectangle {
                                    width: mdTrack.width * win.clamp(bridge.cursorDelay / 15.0, 0, 1)
                                    height: parent.height
                                    radius: 4
                                    color: win.accent
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    anchors.margins: -12
                                    cursorShape: Qt.PointingHandCursor
                                    preventStealing: true
                                    onPressed: parent.parent.setFromX(mouseX)
                                    onPositionChanged: if (pressed) parent.parent.setFromX(mouseX)
                                }
                            }
                            Text {
                                anchors.right: parent.right
                                text: bridge.cursorDelay + "s"
                                color: win.accent
                                font.pixelSize: 14
                                font.weight: Font.Bold
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }
                        Item {
                            width: mCol.width
                            height: 34
                            function setFromX(x) {
                                bridge.setCursorSize(Math.round(win.clamp(x / mcTrack.width, 0, 1) * 48) + 12)
                            }
                            Text { text: "Pointer size"; color: "#f4f6fb"; font.pixelSize: 14; anchors.verticalCenter: parent.verticalCenter }
                            Rectangle {
                                id: mcTrack
                                x: 260
                                width: parent.width - 340
                                height: 8
                                radius: 4
                                anchors.verticalCenter: parent.verticalCenter
                                color: Qt.rgba(1, 1, 1, 0.12)
                                Rectangle {
                                    width: mcTrack.width * win.clamp((bridge.cursorSize - 12) / 48.0, 0, 1)
                                    height: parent.height
                                    radius: 4
                                    color: win.accent
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    anchors.margins: -12
                                    cursorShape: Qt.PointingHandCursor
                                    preventStealing: true
                                    onPressed: parent.parent.setFromX(mouseX)
                                    onPositionChanged: if (pressed) parent.parent.setFromX(mouseX)
                                }
                            }
                            Text {
                                anchors.right: parent.right
                                text: bridge.cursorSize + "px"
                                color: win.accent
                                font.pixelSize: 14
                                font.weight: Font.Bold
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }
                        Text {
                            text: "Pointer size applies to apps launched afterwards (Xcursor.size)."
                            color: Qt.rgba(1, 1, 1, 0.35)
                            font.pixelSize: 12
                            wrapMode: Text.Wrap
                            width: parent.width
                        }
                        Rectangle { width: parent.width; height: 1; color: Qt.rgba(1, 1, 1, 0.08) }
                        Text { text: "SHORTCUTS"; color: Qt.rgba(1,1,1,0.45); font.pixelSize: 11; font.letterSpacing: 2 }
                        Column {
                            width: parent.width
                            spacing: 6
                            Repeater {
                                model: [
                                    "Home / Super - return to Aura OS (apps are backgrounded)",
                                    "Home / Super x2 - close PiP + open Control Center",
                                    "Hold a tile (or right-click) - quick menu: PiP, halves, close",
                                    "Esc - close panels · Arrows/Enter - navigate & launch"
                                ]
                                Text {
                                    text: "·  " + modelData
                                    color: Qt.rgba(1, 1, 1, 0.65)
                                    font.pixelSize: 13
                                    wrapMode: Text.Wrap
                                    width: mCol.width
                                }
                            }
                        }
                    }
                }
            }

            // ---------------- section: Power ----------------------------------
            Component {
                id: powerC
                Flickable {
                    clip: true
                    contentHeight: pCol.height + 24
                    Column {
                        id: pCol
                        width: parent.width
                        spacing: 10
                        Text { text: "POWER"; color: Qt.rgba(1,1,1,0.45); font.pixelSize: 11; font.letterSpacing: 2 }
                        Flow {
                            width: parent.width
                            spacing: 10
                            Repeater {
                                model: [
                                    { t: "Sleep", a: "suspend", arm: false, red: false },
                                    { t: "Restart", a: "reboot", arm: true, red: false },
                                    { t: "Shut Down", a: "poweroff", arm: true, red: true }
                                ]
                                Rectangle {
                                    width: 140; height: 46; radius: 12
                                    property bool armed: false
                                    color: armed ? (modelData.red ? "#c0392b" : win.accent)
                                                 : Qt.rgba(1, 1, 1, 0.07)
                                    border.color: Qt.rgba(1, 1, 1, 0.14)
                                    Timer { id: disarmP; interval: 3000; onTriggered: parent.armed = false }
                                    Text {
                                        anchors.centerIn: parent
                                        text: parent.armed ? "Confirm?" : modelData.t
                                        color: "#fff"
                                        font.pixelSize: 14
                                    }
                                    MouseArea {
                                        anchors.fill: parent
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            if (!modelData.arm) bridge.powerAction(modelData.a)
                                            else if (parent.armed) {
                                                parent.armed = false
                                                bridge.powerAction(modelData.a)
                                            } else { parent.armed = true; disarmP.restart() }
                                        }
                                    }
                                }
                            }
                        }
                        Rectangle { width: parent.width; height: 1; color: Qt.rgba(1, 1, 1, 0.08) }
                        Text { text: "SESSION"; color: Qt.rgba(1,1,1,0.45); font.pixelSize: 11; font.letterSpacing: 2 }
                        Row {
                            spacing: 10
                            Rectangle {
                                width: 150; height: 46; radius: 12
                                color: win.accent
                                Text { anchors.centerIn: parent; text: "Screen Off Now"; color: "#fff"; font.pixelSize: 14; font.weight: Font.DemiBold }
                                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: bridge.screenOff() }
                            }
                            Rectangle {
                                width: 150; height: 46; radius: 12
                                color: Qt.rgba(1, 1, 1, 0.07)
                                border.color: Qt.rgba(1, 1, 1, 0.14)
                                Text { anchors.centerIn: parent; text: "Log Out"; color: "#fff"; font.pixelSize: 14 }
                                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: bridge.logout() }
                            }
                        }
                        Text {
                            text: "Log Out ends the Aura session and returns to the login screen. Aura OS stays your default session."
                            color: Qt.rgba(1, 1, 1, 0.35)
                            font.pixelSize: 12
                            wrapMode: Text.Wrap
                            width: parent.width
                        }
                    }
                }
            }

            // ---------------- section: About -----------------------------------
            Component {
                id: aboutC
                Flickable {
                    clip: true
                    contentHeight: abCol.height + 24
                    Column {
                        id: abCol
                        width: parent.width
                        spacing: 12
                        Row {
                            spacing: 14
                            Rectangle {
                                width: 64; height: 64; radius: 18
                                color: win.accent
                                Text {
                                    anchors.centerIn: parent
                                    text: "A"
                                    color: "#fff"
                                    font.pixelSize: 34
                                    font.weight: Font.Bold
                                }
                            }
                            Column {
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 4
                                Text { text: "Aura OS"; color: "#f4f6fb"; font.pixelSize: 22; font.weight: Font.Bold }
                                Text { text: "Native Kiosk Shell · v" + auraVersion; color: Qt.rgba(1, 1, 1, 0.5); font.pixelSize: 13 }
                            }
                        }
                        Rectangle {
                            width: abCol.width
                            height: aboutText.height + 28
                            radius: 12
                            color: Qt.rgba(1, 1, 1, 0.05)
                            Text {
                                id: aboutText
                                x: 14
                                y: 14
                                width: parent.width - 28
                                text: bridge.sysInfo === "" ? "Gathering system info..." : bridge.sysInfo
                                color: Qt.rgba(1, 1, 1, 0.75)
                                font.pixelSize: 13
                                font.letterSpacing: 0.5
                                lineHeight: 1.25
                            }
                        }
                        Rectangle {
                            width: 160; height: 40; radius: 12
                            color: Qt.rgba(1, 1, 1, 0.07)
                            border.color: Qt.rgba(1, 1, 1, 0.14)
                            Text { anchors.centerIn: parent; text: "Refresh info"; color: "#fff"; font.pixelSize: 13 }
                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: bridge.refreshSysInfo() }
                        }
                        Text { text: "THE AURA SHELL"; color: Qt.rgba(1,1,1,0.45); font.pixelSize: 11; font.letterSpacing: 2 }
                        Column {
                            width: parent.width
                            spacing: 6
                            Repeater {
                                model: [
                                    "Every external app is forced borderless: centered + fullscreen",
                                    "Long-press any tile for PiP / split-screen quick actions",
                                    "The glass panels refract the live wave background in real time",
                                    "All settings persist in ~/.config/aura-os/settings.json"
                                ]
                                Text {
                                    text: "·  " + modelData
                                    color: Qt.rgba(1, 1, 1, 0.65)
                                    font.pixelSize: 13
                                    wrapMode: Text.Wrap
                                    width: abCol.width
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // ============================== WI-FI PASSWORD DIALOG ====================
    Item {
        id: pwDialog
        z: 11
        anchors.fill: parent
        visible: win.pwOpen
        opacity: win.pwOpen ? 1.0 : 0.0
        enabled: win.pwOpen
        Behavior on opacity { NumberAnimation { duration: 180 } }

        Rectangle { anchors.fill: parent; color: Qt.rgba(0, 0, 0, 0.6) }
        MouseArea { anchors.fill: parent; onClicked: { } }

        Rectangle {
            id: pwPanel
            anchors.centerIn: parent
            width: 420
            height: 210
            radius: 22
            color: Qt.rgba(0.09, 0.11, 0.19, 0.97)
            border.color: Qt.rgba(1, 1, 1, 0.16)
            MouseArea { anchors.fill: parent; onClicked: { } }

            Column {
                x: 24
                y: 22
                width: parent.width - 48
                spacing: 14
                Text {
                    text: "Connect to " + win.pwTargetSsid
                    color: "#f4f6fb"
                    font.pixelSize: 17
                    font.weight: Font.Bold
                    elide: Text.ElideRight
                    width: parent.width
                }
                Rectangle {
                    width: parent.width
                    height: 42
                    radius: 10
                    color: Qt.rgba(1, 1, 1, 0.08)
                    border.color: pwInput.activeFocus ? win.accent : Qt.rgba(1, 1, 1, 0.15)
                    TextInput {
                        id: pwInput
                        anchors.fill: parent
                        anchors.margins: 10
                        color: "#f4f6fb"
                        font.pixelSize: 14
                        echoMode: TextInput.Password
                        clip: true
                        focus: win.pwOpen
                        Keys.onReturnPressed: { bridge.connectWifi(win.pwTargetSsid, text); win.pwOpen = false }
                        Keys.onEnterPressed: { bridge.connectWifi(win.pwTargetSsid, text); win.pwOpen = false }
                    }
                }
                Row {
                    spacing: 10
                    Rectangle {
                        width: 130; height: 42; radius: 12
                        color: win.accent
                        Text { anchors.centerIn: parent; text: "Connect"; color: "#fff"; font.pixelSize: 14; font.weight: Font.DemiBold }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                bridge.connectWifi(win.pwTargetSsid, pwInput.text)
                                win.pwOpen = false
                            }
                        }
                    }
                    Rectangle {
                        width: 110; height: 42; radius: 12
                        color: Qt.rgba(1, 1, 1, 0.07)
                        border.color: Qt.rgba(1, 1, 1, 0.14)
                        Text { anchors.centerIn: parent; text: "Cancel"; color: "#fff"; font.pixelSize: 14 }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: win.pwOpen = false
                        }
                    }
                }
            }
        }
    }

    // ============================== TOAST ====================================
    Rectangle {
        id: toastBox
        z: 12
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 34
        width: Math.max(220, toastText.implicitWidth + 48)
        height: 48
        radius: 24
        color: Qt.rgba(0.09, 0.11, 0.19, 0.95)
        border.color: win.accent
        border.width: 1
        opacity: 0
        visible: opacity > 0.01
        Text {
            id: toastText
            anchors.centerIn: parent
            text: bridge.toastText
            color: "#f4f6fb"
            font.pixelSize: 14
            font.weight: Font.DemiBold
        }
        SequentialAnimation {
            id: toastAnim
            NumberAnimation { target: toastBox; property: "opacity"; to: 1.0; duration: 160 }
            PauseAnimation { duration: 2800 }
            NumberAnimation { target: toastBox; property: "opacity"; to: 0.0; duration: 320 }
        }
    }

    // ============================== EMPTY STATE ==============================
    Item {
        z: 5
        anchors.centerIn: parent
        width: 480
        height: 200
        visible: !bridge.rows || bridge.rows.length === 0
        Rectangle {
            anchors.fill: parent
            radius: 24
            color: Qt.rgba(0.09, 0.11, 0.19, 0.90)
            border.color: Qt.rgba(1, 1, 1, 0.14)
        }
        Column {
            anchors.centerIn: parent
            spacing: 12
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "No applications found"
                color: "#f4f6fb"
                font.pixelSize: 20
                font.weight: Font.Bold
            }
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "Install apps, then click Rescan below."
                color: Qt.rgba(1, 1, 1, 0.55)
                font.pixelSize: 13
            }
            Rectangle {
                anchors.horizontalCenter: parent.horizontalCenter
                width: 140; height: 42; radius: 12
                color: win.accent
                Text { anchors.centerIn: parent; text: "Rescan"; color: "#fff"; font.pixelSize: 14; font.weight: Font.DemiBold }
                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: bridge.rescan() }
            }
        }
    }

    // ============================== BRIDGE SIGNALS ===========================
    Connections {
        target: bridge
        onHomeTap: win.closeAllOverlays()
        onHomeDoubleTap: {
            win.settingsOpen = false
            win.menuOpen = false
            win.ccOpen = true
        }
        onToastArrived: {
            toastText.text = bridge.toastText
            toastAnim.restart()
        }
    }
}
AURA_UI_QML_EOF


cat > "$AURA_DIR/aura-session.sh" <<'AURA_SESSION_EOF'
#!/bin/bash
# =========================================================================
# Aura OS - X11 session launcher (registered in /usr/share/xsessions)
# =========================================================================
export PATH="/usr/local/bin:/usr/bin:/bin:/usr/local/games:/usr/games"
AURA_DIR="@AURA_DIR@"

LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/aura-os"
mkdir -p "$LOG_DIR" 2>/dev/null || LOG_DIR="$HOME/.aura-os"
mkdir -p "$HOME/.aura-os" 2>/dev/null

# Emergency escape hatch: AURA_SOFTWARE=1 forces the CPU rasterizer
if [ "${AURA_SOFTWARE:-0}" = "1" ]; then
    export QT_QUICK_BACKEND=software
fi

if [ -n "${DISPLAY:-}" ]; then
    # kiosk hygiene: no screen blanking while the shell is up
    if command -v xset >/dev/null 2>&1; then
        xset s off          >/dev/null 2>&1
        xset s noblank      >/dev/null 2>&1
        xset -dpms          >/dev/null 2>&1
    fi
    # global Super / remote-Home key handling
    if command -v xbindkeys >/dev/null 2>&1; then
        pkill -x xbindkeys 2>/dev/null
        sleep 0.2
        xbindkeys -f "$AURA_DIR/xbindkeysrc" >/dev/null 2>&1 &
    fi
fi

PY3="$(command -v python3 || echo /usr/bin/python3)"
exec "$PY3" "$AURA_DIR/main.py" >> "$LOG_DIR/session.log" 2>&1
AURA_SESSION_EOF


cat > "$AURA_DIR/aura-home.sh" <<'AURA_HOME_EOF'
#!/bin/bash
# Aura OS - Universal Home trigger (bound to Super / XF86HomePage via xbindkeys)
FIFO="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/aura-os/home.fifo"
[ -p "$FIFO" ] || exit 0
if command -v timeout >/dev/null 2>&1; then
    timeout 1 sh -c "printf 'HOME\n' > \"$FIFO\"" 2>/dev/null
else
    ( printf 'HOME\n' > "$FIFO" ) 2>/dev/null
fi
exit 0
AURA_HOME_EOF


cat > "$AURA_DIR/aura-brightness.sh" <<'AURA_BRIGHTNESS_EOF'
#!/bin/bash
# Aura OS - software brightness step via xrandr (up|down)
DIR="${1:-up}"
CUR="$(xrandr --current --verbose 2>/dev/null | awk '/connected/{f=1} f && /Brightness:/{print $2; exit}')"
CUR="${CUR:-1.0}"
V="$(awk -v c="$CUR" -v d="$DIR" 'BEGIN{
    if (d=="down") c-=0.10; else c+=0.10;
    if (c>1.0) c=1.0; if (c<0.15) c=0.15;
    printf "%.2f", c }')"
for OUT in $(xrandr --current 2>/dev/null | awk '/ connected/{print $1}'); do
    xrandr --output "$OUT" --brightness "$V" 2>/dev/null
done
exit 0
AURA_BRIGHTNESS_EOF


cat > "$AURA_DIR/xbindkeysrc" <<'AURA_XBINDKEYSRC_EOF'
# =========================================================================
# Aura OS - global key bindings (loaded via: xbindkeys -f <this file>)
# =========================================================================
keystate_numlock   = enable
keystate_capslock  = enable
keystate_scrolllock= enable

# ---- Universal Home: Super keys + remote Home button --------------------
"@AURA_DIR@/aura-home.sh"
    m:0x40 + c:133
"@AURA_DIR@/aura-home.sh"
    m:0x40 + c:134
"@AURA_DIR@/aura-home.sh"
    c:180

# ---- Media transport (routed through playerctl / MPRIS) -----------------
"playerctl play-pause"
    XF86AudioPlay
"playerctl play-pause"
    XF86AudioPause
"playerctl stop"
    XF86AudioStop
"playerctl next"
    XF86AudioNext
"playerctl previous"
    XF86AudioPrev

# ---- Volume --------------------------------------------------------------
"pactl set-sink-volume @DEFAULT_SINK@ +5%"
    XF86AudioRaiseVolume
"pactl set-sink-volume @DEFAULT_SINK@ -5%"
    XF86AudioLowerVolume
"pactl set-sink-mute @DEFAULT_SINK@ toggle"
    XF86AudioMute

# ---- Brightness ----------------------------------------------------------
"@AURA_DIR@/aura-brightness.sh up"
    XF86MonBrightnessUp
"@AURA_DIR@/aura-brightness.sh down"
    XF86MonBrightnessDown
AURA_XBINDKEYSRC_EOF


chmod 755 "$AURA_DIR/aura-session.sh" "$AURA_DIR/aura-home.sh" \
          "$AURA_DIR/aura-brightness.sh"
chmod 644 "$AURA_DIR/main.py" "$AURA_DIR/ui.qml" "$AURA_DIR/xbindkeysrc"
# bake the real install prefix into path-bearing files
sed -i "s|@AURA_DIR@|$AURA_DIR|g" "$AURA_DIR/aura-session.sh" \
    "$AURA_DIR/xbindkeysrc"
chown -R root:root "$AURA_DIR" 2>/dev/null || true
ok "Project files written."

# --------------------------------------------------------------------------
# [3/6] register the X11 session
# --------------------------------------------------------------------------
info "[3/6] Registering Aura OS X11 session..."
mkdir -p "$XS_DIR" "$APP_DIR"
cat > "$XS_DIR/aura-os.desktop" <<'DESK_EOF'
[Desktop Entry]
Encoding=UTF-8
Type=Application
Name=Aura OS
Comment=Aura OS Kiosk Shell (Qt Quick / GPU)
Exec=@AURA_DIR@/aura-session.sh
TryExec=@AURA_DIR@/aura-session.sh
DesktopNames=AURA
DESK_EOF

cat > "$APP_DIR/aura-os-preview.desktop" <<'PREV_EOF'
[Desktop Entry]
Encoding=UTF-8
Type=Application
Name=Aura OS (Preview)
Comment=Run the Aura OS kiosk shell inside the current session
Exec=@AURA_DIR@/aura-session.sh
Icon=video-display
Terminal=false
Categories=System;
PREV_EOF
sed -i "s|@AURA_DIR@|$AURA_DIR|g" "$XS_DIR/aura-os.desktop" \
    "$APP_DIR/aura-os-preview.desktop"
ok "Session registered in $XS_DIR (and a preview launcher added)."

# --------------------------------------------------------------------------
# [4/6] headless self-test (offscreen) — MUST pass before touching defaults
# --------------------------------------------------------------------------
info "[4/6] Running headless self-test (offscreen QML load)..."
python3 "$AURA_DIR/main.py" --selftest >>"$LOG_FILE" 2>&1
if [ "$?" -eq 0 ]; then
    SELFTEST_OK=1
    ok "Self-test passed: QML engine + AuraBridge verified."
else
    warn "Self-test FAILED — see below. Default session will NOT be changed."
    tail -n 40 "$LOG_FILE" 2>/dev/null | sed 's/^/    /'
fi

# --------------------------------------------------------------------------
# [5/6] default session via AccountsService (+ LightDM when present)
# --------------------------------------------------------------------------
if [ "$SELFTEST_OK" -eq 1 ]; then
    info "[5/6] Setting default session for $TARGET_USER ..."
    AS_DIR="/var/lib/AccountsService/users"
    AS_FILE="$AS_DIR/$TARGET_USER"
    if [ -d "$AS_DIR" ]; then
        mkdir -p "$AS_DIR"
        if [ -f "$AS_FILE" ] && grep -q '^\[User\]' "$AS_FILE"; then
            sed -i -e '/^Session=/d' -e '/^XSession=/d' \
                -e 's/^\[User\]/[User]\nSession=aura-os\nXSession=aura-os/' "$AS_FILE"
        else
            printf '[User]\nSession=aura-os\nXSession=aura-os\n' > "$AS_FILE"
        fi
        ok "AccountsService default session → aura-os"
    else
        warn "AccountsService not present — pick 'Aura OS' manually at login."
    fi
    if command -v lightdm-set-defaults >/dev/null 2>&1; then
        lightdm-set-defaults --session aura-os >/dev/null 2>&1 \
            && ok "LightDM default session → aura-os"
    fi
else
    info "[5/6] Skipped (self-test failed)."
fi

# --------------------------------------------------------------------------
# [6/6] test-launch so you can verify the graphics before logging out
# --------------------------------------------------------------------------
printf "\n"
if [ "$NO_TEST" -eq 1 ]; then
    info "[6/6] Test launch skipped (--no-test)."
elif [ "$SELFTEST_OK" -ne 1 ]; then
    info "[6/6] Test launch skipped (self-test failed)."
else
    info "[6/6] Test-launching Aura OS..."
    TEST_DISPLAY="${DISPLAY:-}"
    if [ -z "$TEST_DISPLAY" ] && [ -d /tmp/.X11-unix ]; then
        XS=$(ls /tmp/.X11-unix 2>/dev/null | sed 's/^X//' | head -n1)
        [ -n "$XS" ] && TEST_DISPLAY=":$XS"
    fi
    TEST_XAUTH=""
    if [ "$TARGET_UID" != "0" ]; then
        for c in "$TARGET_HOME/.Xauthority" "/run/user/$TARGET_UID/gdm/Xauthority"; do
            if [ -r "$c" ]; then TEST_XAUTH="$c"; break; fi
        done
    fi
    if [ -z "$TEST_DISPLAY" ]; then
        warn "No X display detected — skipping live test."
        info "Log out and pick 'Aura OS' in the session menu instead."
    elif ! command -v runuser >/dev/null 2>&1; then
        warn "runuser unavailable — skipping live test."
    else
        (
            XAUTHENV=""
            [ -n "$TEST_XAUTH" ] && XAUTHENV="XAUTHORITY=$TEST_XAUTH"
            nohup runuser -u "$TARGET_USER" -- env DISPLAY="$TEST_DISPLAY" $XAUTHENV \
                "$AURA_DIR/aura-session.sh" >/dev/null 2>&1 &
            echo $! > /tmp/aura-os-test.pid
        )
        sleep 6
        WINID="$(runuser -u "$TARGET_USER" -- env DISPLAY="$TEST_DISPLAY" \
            ${TEST_XAUTH:+XAUTHORITY=$TEST_XAUTH} \
            xdotool search --name '^Aura OS$' 2>/dev/null | head -n1)"
        if pgrep -f "$AURA_DIR/main.py" >/dev/null 2>&1; then
            if [ -n "$WINID" ]; then
                ok "Aura OS is LIVE (window id $WINID) — check your screen!"
            else
                ok "Aura OS process is running (window may still be fading in)."
            fi
            printf "\n"
            info " ┌─ TEST CONTROLS ─────────────────────────────────────────┐"
            info " │  Super/Home      → background app + return to Aura OS   │"
            info " │  Super/Home ×2   → close PiP + open Control Center      │"
            info " │  Hold a tile     → quick menu: PiP / left / right half  │"
            info " │  ↑ ↓ ← → Enter   → navigate & launch · Esc → controls   │"
            info " │  Control Center  → theme · volume · PiP · All Settings  │"
            info " └─────────────────────────────────────────────────────────┘"
            info " Stop test    : pkill -f $AURA_DIR/main.py"
            info " Session log  : $TARGET_HOME/.local/state/aura-os/session.log"
            info " Install log  : $LOG_FILE"
            printf "\n"
            ok "NEXT: log out → session gear → 'Aura OS' → it is now your DEFAULT."
        else
            warn "Test process exited early — session log tail:"
            tail -n 25 "$TARGET_HOME/.local/state/aura-os/session.log" 2>/dev/null \
                | sed 's/^/    /'
        fi
    fi
fi

printf "\n"
if [ "$SELFTEST_OK" -eq 1 ]; then
    ok "AURA OS installation complete. Enjoy the shell."
else
    warn "Installed, but self-test failed — NOTHING was set as default session."
fi
exit 0
