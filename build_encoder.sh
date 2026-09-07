#!/bin/bash
set -e
export MACOSX_DEPLOYMENT_TARGET="11.0"

echo "=================================================="
echo "   🚀 Building Standalone MediaEngine        "
echo "=================================================="

# Define Path to Custom Icon
ICON_SRC="$HOME/Desktop/Personal/CRF Encode.png"

# 1. Detect Python with Tkinter
PYTHON_EXEC=""
for candidate in python3.12 python3.11 python3.13 python3 /opt/homebrew/bin/python3 /usr/local/bin/python3; do
    if command -v "$candidate" >/dev/null 2>&1; then
        if "$candidate" -c "import tkinter" >/dev/null 2>&1; then
            PYTHON_EXEC="$(command -v "$candidate")"
            echo "✔ Found compatible Python: $PYTHON_EXEC"
            break
        fi
    fi
done

if [ -z "$PYTHON_EXEC" ]; then
    echo "❌ ERROR: No Python with Tkinter found. Run: brew install python-tk"
    exit 1
fi

WORKDIR="$HOME/Desktop/EncoderBuild"
VENV_DIR="/tmp/encoder_build_venv"
BIN_CACHE="$HOME/Desktop/static_bin"

rm -rf "$WORKDIR" "$VENV_DIR"
mkdir -p "$WORKDIR" "$BIN_CACHE"
cd "$WORKDIR"

# 2. Acquire True Static FFmpeg & FFprobe Binaries
echo "📦 Checking standalone FFmpeg/FFprobe binaries..."
ARCH=$(uname -m)

if [ ! -f "$BIN_CACHE/ffmpeg" ] || [ ! -f "$BIN_CACHE/ffprobe" ]; then
    echo "⬇️ Downloading standalone static FFmpeg binaries with VideoToolbox for $ARCH..."
    if [ "$ARCH" = "arm64" ]; then
        URL_FFMPEG="https://ffmpeg.martin-riedl.de/redirect/latest/macos/arm64/release/ffmpeg.zip"
        URL_FFPROBE="https://ffmpeg.martin-riedl.de/redirect/latest/macos/arm64/release/ffprobe.zip"
    else
        URL_FFMPEG="https://ffmpeg.martin-riedl.de/redirect/latest/macos/amd64/release/ffmpeg.zip"
        URL_FFPROBE="https://ffmpeg.martin-riedl.de/redirect/latest/macos/amd64/release/ffprobe.zip"
    fi
    (curl -L -f -o /tmp/ffmpeg.zip "$URL_FFMPEG" && unzip -o /tmp/ffmpeg.zip -d "$BIN_CACHE/" && rm -f /tmp/ffmpeg.zip) || true
    (curl -L -f -o /tmp/ffprobe.zip "$URL_FFPROBE" && unzip -o /tmp/ffprobe.zip -d "$BIN_CACHE/" && rm -f /tmp/ffprobe.zip) || true
    if [ "$ARCH" != "arm64" ] && { [ ! -f "$BIN_CACHE/ffmpeg" ] || [ ! -f "$BIN_CACHE/ffprobe" ]; }; then
        echo "⬇️ Falling back to GitHub & static release mirrors for Intel..."
        (curl -L -f -o /tmp/ffmpeg.zip "https://ffmpeg.martin-riedl.de/redirect/latest/macos/amd64/snapshot/ffmpeg.zip" && unzip -o /tmp/ffmpeg.zip -d "$BIN_CACHE/" && rm -f /tmp/ffmpeg.zip) || true
        (curl -L -f -o /tmp/ffprobe.zip "https://ffmpeg.martin-riedl.de/redirect/latest/macos/amd64/snapshot/ffprobe.zip" && unzip -o /tmp/ffprobe.zip -d "$BIN_CACHE/" && rm -f /tmp/ffprobe.zip) || true
        if [ ! -f "$BIN_CACHE/ffmpeg" ] || [ ! -f "$BIN_CACHE/ffprobe" ]; then
            (curl -L -f -o /tmp/ffmpeg.gz "https://github.com/eugeneware/ffmpeg-static/releases/download/b6.1.1/ffmpeg-darwin-x64.gz" && gzip -d -c /tmp/ffmpeg.gz > "$BIN_CACHE/ffmpeg" && rm -f /tmp/ffmpeg.gz) || true
            (curl -L -f -o /tmp/ffprobe.gz "https://github.com/eugeneware/ffmpeg-static/releases/download/b6.1.1/ffprobe-darwin-x64.gz" && gzip -d -c /tmp/ffprobe.gz > "$BIN_CACHE/ffprobe" && rm -f /tmp/ffprobe.gz) || true
        fi
        if [ ! -f "$BIN_CACHE/ffmpeg" ] || [ ! -f "$BIN_CACHE/ffprobe" ]; then
            (curl -L -f -o /tmp/ffmpeg.zip "https://www.osxexperts.net/ffmpeg80intel.zip" && unzip -o /tmp/ffmpeg.zip -d "$BIN_CACHE/" && rm -f /tmp/ffmpeg.zip) || true
            (curl -L -f -o /tmp/ffprobe.zip "https://www.osxexperts.net/ffprobe80intel.zip" && unzip -o /tmp/ffprobe.zip -d "$BIN_CACHE/" && rm -f /tmp/ffprobe.zip) || true
        fi
    fi
    find "$BIN_CACHE" -mindepth 2 -type f -name "ffmpeg" -exec mv -f {} "$BIN_CACHE/ffmpeg" \; 2>/dev/null || true
    find "$BIN_CACHE" -mindepth 2 -type f -name "ffprobe" -exec mv -f {} "$BIN_CACHE/ffprobe" \; 2>/dev/null || true
    if [ ! -f "$BIN_CACHE/ffmpeg" ] || [ ! -f "$BIN_CACHE/ffprobe" ]; then
        echo "❌ ERROR: Failed to download static FFmpeg/FFprobe binaries from CDN."
        exit 1
    fi
    chmod +x "$BIN_CACHE/ffmpeg" "$BIN_CACHE/ffprobe" 2>/dev/null || true
fi

# 3. Setup Virtualenv & Build Dependencies
echo "📦 Setting up virtual build environment..."
"$PYTHON_EXEC" -m venv "$VENV_DIR"
"$VENV_DIR/bin/pip" install --upgrade pip --quiet
if [ "$ARCH" = "arm64" ]; then
    "$VENV_DIR/bin/pip" install pyinstaller customtkinter tkinterdnd2-universal pillow --quiet || \
    "$VENV_DIR/bin/pip" install pyinstaller customtkinter tkinterdnd2 pillow --quiet
else
    "$VENV_DIR/bin/pip" install pyinstaller customtkinter tkinterdnd2 pillow --quiet || \
    "$VENV_DIR/bin/pip" install pyinstaller customtkinter tkinterdnd2-universal pillow --quiet
fi

# PyInstaller hook for tkinterdnd2
cat << 'HOOKEOF' > hook-tkinterdnd2.py
from PyInstaller.utils.hooks import collect_data_files, collect_dynamic_libs
datas = collect_data_files('tkinterdnd2')
binaries = collect_dynamic_libs('tkinterdnd2')
HOOKEOF

# 4. Write Python Code
cat << 'PYEOF' > video_encoder_gui.py
import os
import sys
import re
import json
import math
import urllib.parse
import unicodedata
import errno
import shutil
import signal
import subprocess
import threading
import queue
from collections import deque
import time
import atexit
import traceback
import tkinter as tk
from tkinter import messagebox, filedialog, colorchooser
import customtkinter as ctk
import webbrowser

try:
    import ctypes
    from ctypes import util
    _cg_lib = ctypes.CDLL(util.find_library("CoreGraphics") or "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
    _cg_lib.CGEventSourceFlagsState.restype = ctypes.c_uint64
    _cg_lib.CGEventSourceFlagsState.argtypes = [ctypes.c_int32]
except Exception:
    _cg_lib = None

try:
    import ctypes
    from ctypes import util
    _carbon = ctypes.cdll.LoadLibrary(util.find_library("Carbon") or "/System/Library/Frameworks/Carbon.framework/Carbon")
    _carbon.GetCurrentKeyModifiers.restype = ctypes.c_uint32
    _carbon.GetCurrentKeyModifiers.argtypes = []
except Exception:
    _carbon = None

def is_macos_option_held():
    if _cg_lib:
        try:
            return bool((_cg_lib.CGEventSourceFlagsState(0) | _cg_lib.CGEventSourceFlagsState(1)) & 0x00080000)
        except Exception:
            pass
    if _carbon:
        try:
            if bool(_carbon.GetCurrentKeyModifiers() & 0x4800):
                return True
        except Exception:
            pass
    return False

_GLOBAL_APP_INSTANCE = None

def safe_killpg(proc_or_pid, *sigs):
    if not proc_or_pid:
        return
    if not sigs:
        sigs = (signal.SIGKILL,)
    try:
        pid = proc_or_pid.pid if hasattr(proc_or_pid, "pid") else int(proc_or_pid)
        my_pgrp = os.getpgrp()
        try:
            pgid = os.getpgid(pid)
            if pgid == my_pgrp or pgid <= 1:
                # Same process group: kill ONLY the single child PID, never the group!
                for sig in sigs:
                    os.kill(pid, sig)
            else:
                for sig in sigs:
                    os.killpg(pgid, sig)
        except (ProcessLookupError, OSError):
            for sig in sigs:
                os.kill(pid, sig)
    except Exception:
        pass

def cleanup_system_ffmpeg(force_all=False):
    """Aggressively clean up orphaned or stuck ffmpeg/ffprobe processes belonging to MediaEngine."""
    try:
        my_pid = os.getpid()
        res = subprocess.run(["ps", "-axww", "-o", "pid,ppid,command"], capture_output=True, text=True, errors="replace")
        if res.returncode == 0:
            for line in res.stdout.strip().splitlines()[1:]:
                parts = line.strip().split(None, 2)
                if len(parts) >= 3:
                    pid_s, ppid_s, cmd_line = parts[0], parts[1], parts[2]
                    cmd_lower = cmd_line.lower()
                    if "ffmpeg" not in cmd_lower and "ffprobe" not in cmd_lower:
                        continue
                    try:
                        pid = int(pid_s)
                        ppid = int(ppid_s)
                    except ValueError:
                        continue
                    if pid == my_pid:
                        continue
                    cmd_str = parts[2].lower()
                    is_child = (ppid == my_pid)
                    is_app_binary = ("mediaengine.app" in cmd_str or "encoderbuild" in cmd_str)
                    is_match = is_child or is_app_binary
                    if is_match:
                        parent_dead = (ppid == 1)
                        if not parent_dead and not is_child:
                            try:
                                os.kill(ppid, 0)
                            except OSError:
                                parent_dead = True
                        if is_child or parent_dead or (force_all and is_app_binary):
                            safe_killpg(pid, signal.SIGCONT, signal.SIGKILL)
    except Exception:
        pass

# cleanup_system_ffmpeg deferred to preflight_check to eliminate launch lag

# Neutralize default CTk wheel bindings to prevent interference with kinetic physics
try:
    import customtkinter.windows.widgets.ctk_scrollable_frame as ctk_sf
    import customtkinter.windows.widgets.ctk_textbox as ctk_tb
    import customtkinter.windows.widgets.ctk_slider as ctk_sl

    ctk_sf.CTkScrollableFrame._set_mouse_wheel_for_children = lambda self, widget, enable=True: None
    ctk_sf.CTkScrollableFrame._enable_mouse_wheel_for_children = lambda self, widget: None
    ctk_sf.CTkScrollableFrame._mouse_wheel_all = lambda self, event: None
    ctk_sf.CTkScrollableFrame._mouse_wheel_windows = lambda self, event: None
    ctk_sf.CTkScrollableFrame._mouse_wheel_linux = lambda self, event: None
    ctk_tb.CTkTextbox._mouse_wheel_all = lambda self, event: None
    for _m in ("_set_mouse_wheel", "_enable_mouse_wheel", "_mouse_wheel", "_mouse_wheel_all", "_mouse_wheel_windows", "_mouse_wheel_linux", "_on_mouse_wheel", "scrolled", "_scrolled"):
        if hasattr(ctk_sl.CTkSlider, _m):
            setattr(ctk_sl.CTkSlider, _m, lambda self, *args, **kwargs: None)
except Exception:
    pass

if getattr(sys, 'frozen', False):
    base_dir = getattr(sys, '_MEIPASS', os.path.dirname(sys.executable))
    parent_dir = os.path.dirname(base_dir)
    for sub in [
        os.path.join(base_dir, "_internal", "tkinterdnd2", "tkdnd"),
        os.path.join(base_dir, "_internal", "tkdnd"),
        os.path.join(base_dir, "tkinterdnd2", "tkdnd"),
        os.path.join(base_dir, "tkdnd"),
        os.path.join(parent_dir, "Resources", "tkdnd"),
        os.path.join(parent_dir, "Resources", "tkinterdnd2", "tkdnd"),
        os.path.join(parent_dir, "Frameworks", "tkinterdnd2", "tkdnd"),
    ]:
        if os.path.isdir(sub):
            os.environ["TKDND_LIBRARY"] = sub
            break

try:
    from tkinterdnd2 import TkinterDnD, DND_FILES
    HAS_TKDND = True
except ImportError:
    HAS_TKDND = False

if getattr(sys, 'frozen', False):
    BUNDLE_DIR = os.path.dirname(sys.executable)
else:
    BUNDLE_DIR = os.path.dirname(os.path.abspath(__file__))
INTERNAL_BIN = os.path.join(BUNDLE_DIR, "bin")

os.environ["PATH"] = f"{BUNDLE_DIR}:{INTERNAL_BIN}:/opt/homebrew/bin:/usr/local/bin:/usr/bin:{os.environ.get('PATH', '')}"

def find_binary(name):
    for candidate_dir in (BUNDLE_DIR, INTERNAL_BIN):
        internal = os.path.join(candidate_dir, name)
        if os.path.exists(internal) and os.access(internal, os.X_OK):
            return internal
    found = shutil.which(name)
    if found and os.path.exists(found):
        return found
    return name

FFMPEG_BIN = find_binary("ffmpeg")
FFPROBE_BIN = find_binary("ffprobe")
SOUND_CHIME = "/System/Library/Sounds/Glass.aiff"
LOG_FILE = os.path.expanduser("~/Library/Logs/MediaEngine.log")
LOG_LOCK = threading.RLock()

def rotate_log_file():
    with LOG_LOCK:
        try:
            if os.path.exists(LOG_FILE) and os.path.getsize(LOG_FILE) > 10 * 1024 * 1024:
                backup = f"{LOG_FILE}.1"
                if os.path.exists(backup):
                    os.remove(backup)
                os.rename(LOG_FILE, backup)
        except Exception:
            pass

rotate_log_file()
USER_PRESETS_DIR = os.path.expanduser("~/Library/Application Support/MediaEngine")
USER_PRESETS_FILE = os.path.join(USER_PRESETS_DIR, "presets.json")
LAST_PRESET_FILE = os.path.join(USER_PRESETS_DIR, "last_preset.txt")
SETTINGS_STATE_FILE = os.path.join(USER_PRESETS_DIR, "settings_expanded.txt")
BATCH_STATE_FILE = os.path.join(USER_PRESETS_DIR, "batch_expanded.txt")
BATCH_HEIGHT_FILE = os.path.join(USER_PRESETS_DIR, "batch_height.txt")
LAST_OUTPUT_DIR_FILE = os.path.join(USER_PRESETS_DIR, "last_output_dir.txt")
THEME_FILE = os.path.join(USER_PRESETS_DIR, "theme_color.txt")
CONCURRENCY_FILE = os.path.join(USER_PRESETS_DIR, "concurrency.txt")
AUTO_START_FILE = os.path.join(USER_PRESETS_DIR, "auto_start.txt")
TAG_SETTINGS_FILE = os.path.join(USER_PRESETS_DIR, "tag_settings.txt")

SUPPORTED_EXTENSIONS = (
    ".mp4", ".mov", ".mkv", ".m4v", ".avi", ".crm",
    ".raw", ".wmv", ".flv", ".webm", ".ts", ".mts", ".m2ts"
)

MEDIA_INSPECT_EXTENSIONS = (
    ".mp4", ".mov", ".mkv", ".m4v", ".avi", ".crm", ".raw", ".wmv", ".flv",
    ".webm", ".ts", ".mts", ".m2ts", ".vob", ".ogv", ".m2v", ".mxf",
    ".jpg", ".jpeg", ".png", ".tiff", ".tif", ".webp", ".heic", ".bmp", ".gif", ".dng",
    ".mp3", ".wav", ".aac", ".m4a", ".flac", ".aiff", ".aif", ".ogg", ".wma", ".opus", ".m4r"
)

def format_date_str(val):
    if not val:
        return None
    s = str(val).strip()
    if ";" in s:
        s = s.split(";")[0].strip()
    elif "," in s and "T" in s:
        s = s.split(",")[0].strip()
    s = re.sub(r"\.\d+", "", s)
    if s.endswith("Z"):
        s = s[:-1].replace("T", " ") + " UTC"
    else:
        s = s.replace("T", " ")
    return s.strip()

def format_detailed_duration(seconds):
    if seconds is None or seconds < 0:
        return "N/A"
    try:
        s = float(seconds)
    except (ValueError, TypeError):
        return str(seconds)
    total_sec = int(s)
    ms = int(round((s - total_sec) * 1000))
    hours = total_sec // 3600
    mins = (total_sec % 3600) // 60
    secs = total_sec % 60
    parts = []
    if hours > 0:
        parts.append(f"{hours} h")
    if mins > 0 or hours > 0:
        parts.append(f"{mins} min")
    parts.append(f"{secs} s")
    if ms > 0 and hours == 0:
        parts.append(f"{ms} ms")
    human = " ".join(parts)
    clock = f"{hours:02d}:{mins:02d}:{secs:02d}.{ms:03d}" if hours > 0 else f"{mins:02d}:{secs:02d}.{ms:03d}"
    return f"{human} ({clock})"

def format_bitrate_str(bps):
    if not bps:
        return "N/A"
    try:
        b = float(bps)
    except (ValueError, TypeError):
        return str(bps)
    if b >= 1_000_000_000:
        return f"{b / 1_000_000_000:.2f} Gb/s"
    elif b >= 1_000_000:
        return f"{b / 1_000_000:.1f} Mb/s"
    elif b >= 1_000:
        return f"{b / 1_000:.1f} kb/s"
    return f"{int(b)} b/s"

def format_bytes_size_str(n_bytes, total_bytes=None):
    if not n_bytes:
        return "N/A"
    try:
        b = float(n_bytes)
    except (ValueError, TypeError):
        return str(n_bytes)
    if b >= (1024**3):
        h_str = f"{b / (1024**3):.2f} GiB"
    elif b >= (1024**2):
        h_str = f"{b / (1024**2):.1f} MiB"
    elif b >= 1024:
        h_str = f"{b / 1024:.1f} KiB"
    else:
        h_str = f"{int(b)} Bytes"
    comma_b = f"{int(b):,}"
    if total_bytes and total_bytes > 0:
        pct = (b / total_bytes) * 100.0
        return f"{h_str} ({comma_b} bytes, {pct:.1f}%)"
    return f"{h_str} ({comma_b} bytes)"

def get_common_resolution_label(width, height):
    try:
        w, h = int(width), int(height)
    except Exception:
        return ""
    mapping = {
        (7680, 4320): "8K UHD", (3840, 2160): "4K UHD", (4096, 2160): "DCI 4K",
        (2560, 1440): "2K QHD", (2048, 1080): "2K DCI", (1920, 1080): "Full HD 1080p",
        (1280, 720): "HD 720p", (720, 480): "NTSC 480p", (720, 576): "PAL 576p",
        (1080, 1920): "Vertical Full HD", (2160, 3840): "Vertical 4K"
    }
    label = mapping.get((w, h))
    return f" ({label})" if label else ""

def analyze_pix_fmt(pix_fmt, raw_bits=None):
    pf = str(pix_fmt or "").lower()
    bit_depth = None
    if raw_bits:
        try:
            bit_depth = f"{int(raw_bits)}-Bit"
        except (ValueError, TypeError):
            pass
    if not bit_depth:
        if pf in ("nv12", "nv21", "nv16", "yuv420p", "yuv422p", "yuv444p"):
            bit_depth = "8-Bit"
        elif any(x in pf for x in ("16le", "16be", "16")):
            bit_depth = "16-Bit"
        elif any(x in pf for x in ("12le", "12be", "12")):
            bit_depth = "12-Bit"
        elif any(x in pf for x in ("10le", "10be", "10", "p010", "p210")):
            bit_depth = "10-Bit"
        elif any(x in pf for x in ("9le", "9be", "9")):
            bit_depth = "9-Bit"
        elif pf:
            bit_depth = "8-Bit"
        else:
            bit_depth = "N/A"

    chroma = "N/A"
    if any(x in pf for x in ("420", "nv12", "nv21", "p010", "yuvj420")):
        chroma = "4:2:0"
    elif any(x in pf for x in ("422", "nv16", "p210", "yuvj422")):
        chroma = "4:2:2"
    elif any(x in pf for x in ("444", "nv24", "yuvj444", "rgb", "bgr")):
        chroma = "4:4:4"
    elif "411" in pf:
        chroma = "4:1:1"
    elif any(x in pf for x in ("gray", "ya8", "ya16")):
        chroma = "Monochrome (4:0:0)"
    return chroma, bit_depth

def get_codec_config_box(codec_name, codec_tag):
    cn = str(codec_name or "").lower()
    ct = str(codec_tag or "").strip()
    if "hevc" in cn or "h265" in cn or "hvc1" in ct or "hev1" in ct:
        return "hvcC"
    elif "h264" in cn or "avc" in cn or "avc1" in ct:
        return "avcC"
    elif "vp9" in cn or "vp09" in ct:
        return "vpcC"
    elif "av1" in cn or "av01" in ct:
        return "av1C"
    elif "prores" in cn or "apc" in ct:
        return "fiel / colr"
    elif "mp4v" in ct:
        return "esds"
    elif "aac" in cn or "mp4a" in ct:
        return "esds"
    elif "ac3" in cn or "ac-3" in cn:
        return "dac3"
    elif "eac3" in cn:
        return "dec3"
    return ct or "N/A"

def get_frame_rate_mode(stream):
    r_str = stream.get("r_frame_rate", "")
    avg_str = stream.get("avg_frame_rate", "")
    if r_str and avg_str and r_str != "0/0" and avg_str != "0/0":
        return "Constant (CFR)" if r_str == avg_str else "Variable (VFR)"
    return "Constant (CFR)"

def calculate_bpp(bitrate, width, height, fps):
    try:
        b = float(bitrate)
        w = float(width)
        h = float(height)
        f = float(fps)
        if w > 0 and h > 0 and f > 0 and b > 0:
            return round(b / (w * h * f), 3)
    except Exception:
        pass
    return None

def parse_stream_fps_val(stream):
    for k in ("avg_frame_rate", "r_frame_rate"):
        val = stream.get(k)
        if val and val != "0/0" and val != "N/A":
            if "/" in val:
                num, den = val.split("/", 1)
                try:
                    den_f = float(den)
                    if den_f > 0:
                        return float(num) / den_f
                except (ValueError, ZeroDivisionError):
                    pass
            else:
                try:
                    return float(val)
                except ValueError:
                    pass
    return None

INSPECTOR_EXTENSIONS = (
    ".mp4", ".mov", ".mkv", ".m4v", ".avi", ".crm", ".raw", ".wmv", ".flv",
    ".webm", ".ts", ".mts", ".m2ts", ".wav", ".mp3", ".aac", ".flac", ".m4a",
    ".jpg", ".jpeg", ".png", ".tiff", ".webp", ".bmp", ".heic", ".exr"
)

_VT_422_SUPPORT = None
def check_vt_422_support():
    global _VT_422_SUPPORT
    if _VT_422_SUPPORT is not None:
        return _VT_422_SUPPORT
    try:
        ffmpeg_exec = find_binary("ffmpeg")
        test_cmd = [
            ffmpeg_exec, "-f", "lavfi", "-i", "nullsrc=s=256x256:d=0.04",
            "-c:v", "hevc_videotoolbox", "-profile:v", "main42210",
            "-pix_fmt", "p210le", "-allow_sw", "0", "-f", "null", "-"
        ]
        res = subprocess.run(test_cmd, capture_output=True, text=True, timeout=15)
        _VT_422_SUPPORT = (res.returncode == 0)
    except Exception:
        _VT_422_SUPPORT = False
    return _VT_422_SUPPORT

HAS_VT_422 = check_vt_422_support()
DEFAULT_CHROMA = "10-Bit 4:2:2" if HAS_VT_422 else "10-Bit 4:2:0"

_VT_SPATIAL_AQ_SUPPORT = None
def check_vt_spatial_aq_support():
    global _VT_SPATIAL_AQ_SUPPORT
    if _VT_SPATIAL_AQ_SUPPORT is not None:
        return _VT_SPATIAL_AQ_SUPPORT
    try:
        ffmpeg_exec = find_binary("ffmpeg")
        res = subprocess.run([ffmpeg_exec, "-h", "encoder=hevc_videotoolbox"], capture_output=True, text=True, timeout=15)
        _VT_SPATIAL_AQ_SUPPORT = "spatial_aq" in (res.stdout + res.stderr)
    except Exception:
        _VT_SPATIAL_AQ_SUPPORT = False
    return _VT_SPATIAL_AQ_SUPPORT

HAS_VT_SPATIAL_AQ = check_vt_spatial_aq_support()

def get_default_presets():
    chroma = "10-Bit 4:2:2" if HAS_VT_422 else "10-Bit 4:2:0"
    return {
        "Log Footage": {
            "codec": "HEVC (H.265)",
            "encoder": "AppleMediaEngine",
            "chroma": chroma,
            "quality": "69",
            "quality_encoder": "AppleMediaEngine",
            "denoise": "10"
        },
        "Non-Log Footage": {
            "codec": "HEVC (H.265)",
            "encoder": "AppleMediaEngine",
            "chroma": chroma,
            "quality": "58",
            "quality_encoder": "AppleMediaEngine",
            "denoise": "15"
        },
        "Custom": {
            "codec": "HEVC (H.265)",
            "encoder": "AppleMediaEngine",
            "chroma": chroma,
            "quality": "69",
            "quality_encoder": "AppleMediaEngine",
            "denoise": "10"
        }
    }

DEFAULT_PRESETS = get_default_presets()

PRIMARIES_MAP = {
    "bt709": 1, "bt470m": 4, "bt470bg": 5, "smpte170m": 6, "smpte240m": 7,
    "film": 8, "bt2020": 9, "bt2020-10": 9, "bt2020-12": 9, "bt2020_10": 9,
    "bt2020_12": 9, "smpte428": 10, "smpte431": 11, "smpte432": 12,
    "dci-p3": 11, "dci_p3": 11, "p3": 12, "display-p3": 12, "display_p3": 12, "jedec-p22": 22
}

TRANSFER_MAP = {
    "bt709": 1, "gamma22": 4, "gamma28": 5, "smpte170m": 6, "smpte240m": 7,
    "linear": 8, "log100": 9, "log316": 10, "iec61966-2-4": 11, "bt1361e": 12,
    "iec61966-2-1": 13, "srgb": 13, "bt2020": 14, "bt2020-10": 14, "bt2020-12": 15,
    "bt2020_10": 14, "bt2020_12": 15, "smpte2084": 16, "pq": 16, "smpte428": 17,
    "arib-std-b67": 18, "arib_std_b67": 18, "hlg": 18
}

MATRIX_MAP = {
    "gbr": 0, "rgb": 0, "bt709": 1, "fcc": 4, "bt470bg": 5, "smpte170m": 6,
    "smpte240m": 7, "ycgco": 8, "bt2020nc": 9, "bt2020_ncl": 9, "bt2020": 9,
    "bt2020c": 10, "bt2020_cl": 10, "bt2020_c": 10, "smpte2085": 11,
    "chroma-derived-nc": 12, "chroma-derived-c": 13, "ictcp": 14
}

FFMPEG_CANONICAL_PRIMARIES = {
    "bt709": "bt709", "bt470m": "bt470m", "bt470bg": "bt470bg", "smpte170m": "smpte170m",
    "smpte240m": "smpte240m", "film": "film", "bt2020": "bt2020", "bt2020-10": "bt2020",
    "bt2020-12": "bt2020", "bt2020_10": "bt2020", "bt2020_12": "bt2020", "smpte428": "smpte428",
    "smpte431": "smpte431", "dci-p3": "smpte431", "dci_p3": "smpte431",
    "smpte432": "smpte432", "p3": "smpte432", "display-p3": "smpte432", "display_p3": "smpte432",
    "jedec-p22": "jedec-p22"
}

FFMPEG_CANONICAL_TRC = {
    "bt709": "bt709", "gamma22": "gamma22", "gamma28": "gamma28", "smpte170m": "smpte170m",
    "smpte240m": "smpte240m", "linear": "linear", "log100": "log100", "log316": "log316",
    "iec61966-2-4": "iec61966-2-4", "bt1361e": "bt1361e", "iec61966-2-1": "iec61966-2-1",
    "srgb": "iec61966-2-1", "bt2020": "bt2020-10", "bt2020-10": "bt2020-10", "bt2020_10": "bt2020-10",
    "bt2020-12": "bt2020-12", "bt2020_12": "bt2020-12", "smpte2084": "smpte2084", "pq": "smpte2084",
    "smpte428": "smpte428", "arib-std-b67": "arib-std-b67", "arib_std_b67": "arib-std-b67", "hlg": "arib-std-b67"
}

FFMPEG_CANONICAL_SPACE = {
    "gbr": "gbr", "rgb": "gbr", "bt709": "bt709", "fcc": "fcc", "bt470bg": "bt470bg",
    "smpte170m": "smpte170m", "smpte240m": "smpte240m", "ycgco": "ycgco",
    "bt2020nc": "bt2020nc", "bt2020_ncl": "bt2020nc", "bt2020": "bt2020nc",
    "bt2020c": "bt2020c", "bt2020_cl": "bt2020c", "bt2020_c": "bt2020c",
    "smpte2085": "smpte2085", "chroma-derived-nc": "chroma-derived-nc",
    "chroma-derived-c": "chroma-derived-c", "ictcp": "ictcp"
}

def get_quality_description(val, encoder):
    try:
        q = int(round(float(val)))
    except Exception:
        q = 69
    is_vt = (encoder == "AppleMediaEngine")
    if is_vt:
        if q >= 90:
            return f"{q} (Extreme / Near Lossless)"
        elif q >= 75:
            return f"{q} (Very High Quality)"
        elif q >= 65:
            return f"{q} (Sweet Spot - Master)"
        elif q >= 55:
            return f"{q} (Sweet Spot - Balanced)"
        elif q >= 45:
            return f"{q} (Medium / Compact)"
        elif q >= 30:
            return f"{q} (Low / Heavy Compression)"
        else:
            return f"{q} (Very Low / Draft)"
    else:
        crf = max(0, min(51, 51 - q))
        if crf == 0:
            return f"{q} (CRF 0 • Lossless)"
        elif crf <= 13:
            return f"{q} (CRF {crf} • Extreme / Near Lossless)"
        elif crf <= 17:
            return f"{q} (CRF {crf} • High / Visually Lossless)"
        elif crf <= 23:
            return f"{q} (CRF {crf} • Sweet Spot - Balanced)"
        elif crf <= 28:
            return f"{q} (CRF {crf} • Medium / Compact)"
        elif crf <= 35:
            return f"{q} (CRF {crf} • Low / Heavy Compression)"
        else:
            return f"{q} (CRF {crf} • Very Low / Draft)"

def get_denoise_description(val):
    try:
        v = float(val)
        val_int = int(round(v * 1000)) if 0.0 < v < 1.0 else int(round(v))
    except Exception:
        val_int = 0
    if val_int <= 0:
        return "0 (Off • Max Speed)"
    elif val_int <= 5:
        return f"{val_int} (Ultra-Fine • CPU)"
    elif val_int <= 12:
        return f"{val_int} (Subtle • CPU)"
    elif val_int <= 22:
        return f"{val_int} (Moderate • CPU)"
    elif val_int <= 38:
        return f"{val_int} (Medium • CPU)"
    elif val_int <= 50:
        return f"{val_int} (Strong • CPU)"
    else:
        return f"{val_int} (Heavy • CPU)"

def get_hardware_media_profile():
    brand = ""
    try:
        res = subprocess.run(["sysctl", "-n", "machdep.cpu.brand_string"], capture_output=True, text=True, errors="replace", timeout=3)
        if res.returncode == 0:
            brand = res.stdout.strip()
    except Exception:
        pass
    b_lower = brand.lower()
    if "ultra" in b_lower:
        return 4, brand or "Apple Silicon Ultra"
    elif "max" in b_lower:
        return 2, brand or "Apple Silicon Max"
    elif any(k in b_lower for k in ("pro", "apple m", "apple")):
        return 1, brand or "Apple Silicon"
    else:
        return 1, (brand or "Generic Mac")

HARDWARE_MEDIA_ENGINES, HARDWARE_CHIP_NAME = 1, "Apple Silicon"

def format_time_duration(seconds, force_hours=False):
    if seconds is None or seconds < 0:
        return "--:--"
    total_sec = int(round(seconds))
    hours = total_sec // 3600
    mins = (total_sec % 3600) // 60
    secs = total_sec % 60
    if hours > 0 or force_hours:
        return f"{hours:02d}:{mins:02d}:{secs:02d}"
    return f"{mins:02d}:{secs:02d}"

def format_eta_str(seconds):
    if seconds is None or seconds < 0 or math.isnan(seconds) or math.isinf(seconds):
        return "ETA: --:--"
    total_sec = int(round(seconds))
    hours = total_sec // 3600
    mins = (total_sec % 3600) // 60
    secs = total_sec % 60
    if hours > 0:
        return f"ETA: {hours:02d}:{mins:02d}:{secs:02d}"
    return f"ETA: {mins:02d}:{secs:02d}"

def format_bytes(size):
    if size is None or size <= 0:
        return "0 B"
    for unit in ['B', 'KB', 'MB', 'GB', 'TB']:
        if size < 1024.0:
            return f"{size:.2f} {unit}" if unit in ('MB', 'GB', 'TB') else f"{int(size)} {unit}"
        size /= 1024.0
    return f"{size:.2f} PB"

def format_bitrate(bps):
    if bps is None or bps <= 0:
        return "--"
    if bps >= 1_000_000:
        return f"{bps / 1_000_000:.1f} Mb/s"
    elif bps >= 1_000:
        return f"{bps / 1_000:.0f} kb/s"
    return f"{bps} b/s"

def clean_file_path(raw_path):
    p = str(raw_path).strip()
    is_url = p.startswith("file://")
    if is_url:
        if p.startswith("file://localhost/"):
            p = "/" + p[17:]
        elif p.startswith("file:///"):
            p = "/" + p[8:]
        elif p.startswith("file://"):
            p = "/" + p[7:].lstrip("/")
        p = urllib.parse.unquote(p)

    # Strip wrapping quotes or brackets
    changed = True
    while changed:
        changed = False
        for open_c, close_c in [('{', '}'), ('"', '"'), ("'", "'")]:
            if p.startswith(open_c) and p.endswith(close_c) and len(p) >= 2:
                p = p[1:-1].strip()
                changed = True

    if is_url:
        p = urllib.parse.unquote(p)
    return unicodedata.normalize('NFC', p).strip()

def get_safe_output_folder(source_dir, dest_root):
    dest_root = os.path.expanduser(dest_root)
    base_name = os.path.basename(os.path.normpath(source_dir))
    if not base_name:
        base_name = "Encoded_Output"

    counter = 0
    while counter < 5000:
        cand_name = base_name if counter == 0 else f"{base_name} {counter}"
        cand_path = os.path.join(dest_root, cand_name)
        if os.path.abspath(cand_path) == os.path.abspath(source_dir) or os.path.exists(cand_path):
            counter += 1
            continue
        try:
            os.makedirs(cand_path, exist_ok=False)
            return cand_name
        except OSError:
            counter += 1
            continue
    return base_name

def get_settings_filename_tag(settings):
    if not settings:
        return ""
    c_raw = settings.get("codec", "HEVC")
    c_name = "HEVC" if "HEVC" in c_raw else ("H.264" if "H.264" in c_raw else c_raw)
    enc = settings.get("encoder", "AppleMediaEngine")
    codec_tag = f"{c_name} CPU" if enc == "CPU" else c_name
    parts = [codec_tag]
    chroma = settings.get("chroma", "")
    if chroma:
        clean_chroma = chroma.replace("-Bit", "bit").replace(":", "")
        parts.append(clean_chroma)
    q = settings.get("quality")
    if q is not None:
        try:
            q_int = int(q)
            q_enc = settings.get("quality_encoder", enc)
            if enc == "AppleMediaEngine":
                vt_q = max(1, min(100, int(round((q_int / 51.0) * 100)))) if q_enc == "CPU" and q_int <= 51 else q_int
                parts.append(f"Q{vt_q}")
            else:
                cpu_q = int(round((q_int / 100.0) * 51)) if (q_enc == "AppleMediaEngine" or q_int > 51) else q_int
                crf_val = max(0, min(51, 51 - cpu_q))
                parts.append(f"CRF{crf_val}")
        except Exception:
            pass
    try:
        d_raw = float(settings.get("denoise", 0) or 0)
        d_int = int(round(d_raw * 1000)) if 0.0 < d_raw < 1.0 else int(round(d_raw))
    except Exception:
        d_int = 0
    if d_int > 0:
        parts.append(f"DN{d_int}")
    return " ".join(parts)

RESERVED_OUTPUT_PATHS = set()
RESERVED_PATHS_LOCK = threading.Lock()

def release_output_path(path):
    if path:
        with RESERVED_PATHS_LOCK:
            RESERVED_OUTPUT_PATHS.discard(os.path.abspath(path))

def generate_safe_output_path(source_file, dest_folder, rel_dir="", ext=".mp4", suffix=""):
    dest_folder = os.path.expanduser(dest_folder)
    target_dir = os.path.join(dest_folder, rel_dir) if rel_dir else dest_folder
    os.makedirs(target_dir, exist_ok=True)
    file_stem, _ = os.path.splitext(os.path.basename(source_file))
    if suffix:
        file_stem = f"{file_stem} [{suffix.strip()}]"

    with RESERVED_PATHS_LOCK:
        counter = 0
        while counter < 5000:
            candidate = os.path.join(target_dir, f"{file_stem}{ext}") if counter == 0 else os.path.join(target_dir, f"{file_stem} {counter}{ext}")
            abs_cand = os.path.abspath(candidate)
            if os.path.abspath(source_file) == abs_cand:
                counter += 1
                continue

            if not os.path.exists(candidate) and abs_cand not in RESERVED_OUTPUT_PATHS:
                RESERVED_OUTPUT_PATHS.add(abs_cand)
                return candidate, abs_cand
            counter += 1
    raise RuntimeError(f"Could not generate safe output path in {target_dir}")

ctk.set_appearance_mode("dark")
ctk.set_default_color_theme("dark-blue")

BG_MAIN = "#080808"
CARD_BG = "#121212"
CARD_BORDER = "#1e1e1e"
TEXT_PRIMARY = "#dedede"
TEXT_MUTED = "#828282"
ACCENT_BLUE = "#46748A"
ACCENT_BLUE_HOVER = "#5b96b3"
NEUTRAL_BTN = "#1a1a1a"
NEUTRAL_BTN_HOVER = "#262626"
DEFAULT_THEME_COLOR = "#46748A"
ULTRA_BG = "#0f191e"
ULTRA_BG_HOVER = "#16252c"
ULTRA_BORDER = "#1c2e37"
ULTRA_TEXT = "#46748A"
ULTRA_TEXT_HOVER = "#5b96b3"
DONE_GREEN = "#30d158"
DONE_BG = "#0a2618"
DONE_BORDER = "#184a2b"
HOLD_TEXT = "#91afbd"
HOLD_BG = "#0e171b"
HOLD_BG_HOVER = "#132026"
HOLD_BORDER = "#1a2c34"

def apply_theme_colors(hex_code):
    global ULTRA_BG, ULTRA_BG_HOVER, ULTRA_BORDER, ULTRA_TEXT, ULTRA_TEXT_HOVER
    global HOLD_TEXT, HOLD_BG, HOLD_BG_HOVER, HOLD_BORDER
    try:
        h = hex_code.lstrip('#')
        if len(h) == 6:
            r, g, b = int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16)
            ULTRA_TEXT = f"#{h}"
            ULTRA_TEXT_HOVER = f"#{min(255, int(r * 1.3)):02x}{min(255, int(g * 1.3)):02x}{min(255, int(b * 1.3)):02x}"
            ULTRA_BG = f"#{int(r * 0.22):02x}{int(g * 0.22):02x}{int(b * 0.22):02x}"
            ULTRA_BG_HOVER = f"#{int(r * 0.32):02x}{int(g * 0.32):02x}{int(b * 0.32):02x}"
            ULTRA_BORDER = f"#{int(r * 0.40):02x}{int(g * 0.40):02x}{int(b * 0.40):02x}"
            HOLD_TEXT = f"#{min(255, int(r * 0.65 + 100)):02x}{min(255, int(g * 0.65 + 100)):02x}{min(255, int(b * 0.65 + 100)):02x}"
            HOLD_BG = f"#{int(r * 0.20):02x}{int(g * 0.20):02x}{int(b * 0.20):02x}"
            HOLD_BG_HOVER = f"#{int(r * 0.28):02x}{int(g * 0.28):02x}{int(b * 0.28):02x}"
            HOLD_BORDER = f"#{int(r * 0.38):02x}{int(g * 0.38):02x}{int(b * 0.38):02x}"
    except Exception:
        pass

def load_saved_theme():
    try:
        if os.path.exists(THEME_FILE):
            with open(THEME_FILE, "r", encoding="utf-8") as f:
                c = f.read().strip()
                if c and c.lower() != "#f5a623":
                    apply_theme_colors(c)
                    return
    except Exception:
        pass
    apply_theme_colors(DEFAULT_THEME_COLOR)

load_saved_theme()

# ============================================================
# 120 FPS UNIVERSAL SUB-PIXEL QUARTZ KINETIC SCROLL ENGINE
# ============================================================
class QuartzKineticScroller:
    def __init__(self, get_view_metrics, set_view_fraction, after_fn, cancel_after_fn=None, smooth_time=0.08, **kwargs):
        self.get_view_metrics = get_view_metrics
        self.set_view_fraction = set_view_fraction
        self.after_fn = after_fn
        self.cancel_after_fn = cancel_after_fn
        self.smooth_time = smooth_time

        self.current_y = 0.0
        self.target_y = 0.0
        self.velocity = 0.0
        self.is_animating = False
        self.last_frame_time = 0.0
        self._anim_job = None

    def sync_position(self):
        if self.is_animating:
            return
        if self._anim_job and self.cancel_after_fn:
            try:
                self.cancel_after_fn(self._anim_job)
            except Exception:
                pass
            self._anim_job = None

        metrics = self.get_view_metrics()
        if metrics:
            view_h, total_h, frac = metrics
            max_scroll = max(0.0, total_h - view_h)
            self.current_y = max(0.0, min(max_scroll, frac * total_h))
            self.target_y = self.current_y
            self.velocity = 0.0
            if total_h > 0:
                self.set_view_fraction(self.current_y / total_h)

    def handle_wheel_input(self, delta_input):
        metrics = self.get_view_metrics()
        if not metrics:
            return
        view_h, total_h, frac = metrics
        if total_h <= view_h or total_h <= 0:
            return

        max_scroll_px = total_h - view_h

        if not self.is_animating:
            self.current_y = max(0.0, min(max_scroll_px, frac * total_h))
            self.target_y = self.current_y
            self.velocity = 0.0

        if abs(delta_input) >= 60:
            norm = delta_input / 120.0
        else:
            norm = delta_input

        magnitude = abs(norm)
        accel = min(4.2, 1.0 + (magnitude * 0.12))
        impulse = -math.copysign((magnitude ** 1.18) * 7.0 * accel, norm)

        self.target_y = max(0.0, min(max_scroll_px, self.target_y + impulse))

        if not self.is_animating:
            self.is_animating = True
            self.last_frame_time = time.perf_counter()
            self._physics_step()

    def _physics_step(self):
        self._anim_job = None
        try:
            metrics = self.get_view_metrics()
            if not metrics:
                self.is_animating = False
                return

            view_h, total_h, frac = metrics
            if total_h <= view_h or total_h <= 0:
                self.is_animating = False
                self.set_view_fraction(0.0)
                return

            max_scroll_px = max(0.0, total_h - view_h)
            self.target_y = max(0.0, min(max_scroll_px, self.target_y))

            now = time.perf_counter()
            dt = min(0.05, max(0.001, now - self.last_frame_time))
            self.last_frame_time = now

            omega = 2.0 / max(0.03, self.smooth_time)
            x = omega * dt
            exp = 1.0 / (1.0 + x + 0.48 * x * x + 0.235 * x * x * x)
            change = self.current_y - self.target_y
            temp = (self.velocity + omega * change) * dt
            self.velocity = (self.velocity - omega * temp) * exp
            next_y = self.target_y + (change + temp) * exp

            if abs(self.target_y - next_y) < 0.4 and abs(self.velocity) < 16.0:
                self.current_y = self.target_y
                self.velocity = 0.0
                if total_h > 0:
                    self.set_view_fraction(self.current_y / total_h)
                self.is_animating = False
            else:
                self.current_y = max(0.0, min(max_scroll_px, next_y))
                if total_h > 0:
                    self.set_view_fraction(self.current_y / total_h)
                self._anim_job = self.after_fn(8, self._physics_step)
        except Exception:
            self.is_animating = False

# ============================================================
# SPLIT VALUE LABEL (LARGE BOLD NUMBER + SUBTLE DESCRIPTOR)
# ============================================================
class SplitValueLabel(ctk.CTkFrame):
    def __init__(self, master, width=235, **kwargs):
        super().__init__(master, fg_color="transparent", width=width, height=24)
        self.pack_propagate(False)
        self.lbl_num = ctk.CTkLabel(
            self, text="", font=ctk.CTkFont(family="SF Pro Text", size=14, weight="bold"),
            text_color=TEXT_PRIMARY, cursor="hand2"
        )
        self.lbl_num.pack(side="left")
        self.lbl_desc = ctk.CTkLabel(
            self, text="", font=ctk.CTkFont(family="SF Pro Text", size=12, weight="normal"),
            text_color=TEXT_MUTED, cursor="hand2"
        )
        self.lbl_desc.pack(side="left", padx=(4, 0), pady=(2, 0))

    def configure(self, **kwargs):
        if "text" in kwargs:
            txt = str(kwargs.pop("text"))
            if " " in txt:
                parts = txt.split(" ", 1)
                self.lbl_num.configure(text=parts[0])
                self.lbl_desc.configure(text=parts[1])
            else:
                self.lbl_num.configure(text=txt)
                self.lbl_desc.configure(text="")
        if kwargs:
            super().configure(**kwargs)

    def bind(self, sequence=None, func=None, add="+"):
        add_val = "+" if add is None else add
        super().bind(sequence, func, add_val)
        self.lbl_num.bind(sequence, func, add_val)
        self.lbl_desc.bind(sequence, func, add_val)

    def cget(self, key):
        if key == "text":
            return f"{self.lbl_num.cget('text')} {self.lbl_desc.cget('text')}".strip()
        return super().cget(key)

def blend_hex(fg_hex, bg_hex, alpha):
    try:
        alpha = max(0.0, min(1.0, float(alpha)))
        if alpha >= 0.999: return fg_hex
        if alpha <= 0.001: return bg_hex
        fg = str(fg_hex).lstrip("#")
        bg = str(bg_hex).lstrip("#")
        if len(fg) != 6 or len(bg) != 6: return fg_hex
        r1, g1, b1 = int(fg[0:2], 16), int(fg[2:4], 16), int(fg[4:6], 16)
        r2, g2, b2 = int(bg[0:2], 16), int(bg[2:4], 16), int(bg[4:6], 16)
        r = int(r1 * alpha + r2 * (1.0 - alpha))
        g = int(g1 * alpha + g2 * (1.0 - alpha))
        b = int(b1 * alpha + b2 * (1.0 - alpha))
        return f"#{min(255, max(0, r)):02x}{min(255, max(0, g)):02x}{min(255, max(0, b)):02x}"
    except Exception:
        return fg_hex

# ============================================================
# 120 FPS ULTRA-PERFORMANCE QUARTZ ACTIVE JOBS CANVAS
# ============================================================

class QuartzActiveJobsCanvas(tk.Canvas):
    CARD_H = 34
    CARD_GAP = 4
    ROW_STEP = 38

    def __init__(self, master, on_layout_needed=None, **kwargs):
        super().__init__(master, bg=CARD_BG, bd=0, highlightthickness=0, relief="flat", **kwargs)
        self.jobs = {}
        self.job_order = []
        self.on_layout_needed = on_layout_needed
        self._anim_job = None
        self._last_tween_time = 0.0
        self.scroller = QuartzKineticScroller(
            get_view_metrics=self._get_scroll_metrics,
            set_view_fraction=self.yview_moveto,
            after_fn=self.after,
            cancel_after_fn=self.after_cancel
        )
        self.bind("<Configure>", self._on_resize)

    def _get_scroll_metrics(self):
        sr = self.cget("scrollregion")
        if not sr: return None
        try:
            parts = [float(p) for p in str(sr).split()]
            total_h = parts[3] - parts[1]
        except Exception:
            return None
        view_h = float(self.winfo_height())
        if total_h <= 0 or view_h <= 0: return None
        return (view_h, total_h, self.yview()[0])

    def handle_wheel_input(self, delta_input):
        self.scroller.handle_wheel_input(delta_input)

    def _get_progress_color(self):
        """Generates a soft, faded accent tint (20% opacity blend over #161616) ensuring high text contrast."""
        try:
            h = ULTRA_TEXT.lstrip('#')
            r, g, b = int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16)
            fr = int(22 + r * 0.20)
            fg = int(22 + g * 0.20)
            fb = int(22 + b * 0.20)
            return f"#{min(255, fr):02x}{min(255, fg):02x}{min(255, fb):02x}"
        except Exception:
            return "#1e2c33"

    def _get_progress_rect_params(self, x1, y1, x2, y2, fill_x, radius=8):
        """Constructs an ultra-smooth rounded progress rect matching the card's native corner curvature."""
        if fill_x <= x1 + 0.5:
            return None, 0.0
        r = max(1.0, min(float(radius), (x2 - x1) / 2.0, (y2 - y1) / 2.0))
        stroke_w = r * 2.0
        cx1 = x1 + r
        cy1 = y1 + r
        cy2 = y2 - r
        cx2 = max(cx1, min(float(x2 - r), fill_x - r))
        return [cx1, cy1, cx2, cy1, cx2, cy2, cx1, cy2], stroke_w

    def _start_tween(self):
        if self._anim_job is None:
            self._last_tween_time = time.perf_counter()
            self._tween_step()

    def _tween_step(self):
        """Critically damped spring tweening & smooth exit fade/collapse interpolation."""
        self._anim_job = None
        now = time.perf_counter()
        dt = min(0.05, max(0.001, now - self._last_tween_time))
        self._last_tween_time = now

        still_animating = False
        needs_full_redraw = False
        dead_ids = []

        for iid in list(self.job_order):
            job = self.jobs.get(iid)
            if not job: continue

            state = job.get("state", "active")

            if state == "holding":
                still_animating = True
                if (now - job.get("hold_start", now)) >= job.get("hold_duration", 0.85):
                    job["state"] = "fading"
                    job["fade_start"] = now
                    needs_full_redraw = True
            elif state == "fading":
                still_animating = True
                needs_full_redraw = True
                elapsed = now - job.get("fade_start", now)
                dur = job.get("exit_duration", 0.38)
                p = min(1.0, elapsed / dur) if dur > 0 else 1.0

                ease_p = p * p * (3.0 - 2.0 * p)
                job["alpha"] = max(0.0, 1.0 - min(1.0, p * 1.25))
                job["height_factor"] = max(0.0, 1.0 - ease_p)

                if p >= 1.0:
                    job["state"] = "dead"
                    dead_ids.append(iid)

            if state in ("active", "holding"):
                target = job.get("target_pct", 0.0)
                cur = job.get("cur_pct", 0.0)
                vel = job.get("velocity", 0.0)

                if abs(target - cur) > 0.04 or abs(vel) > 0.1:
                    omega = 2.0 / 0.22
                    x = omega * dt
                    exp = 1.0 / (1.0 + x + 0.48 * x * x + 0.235 * x * x * x)
                    change = cur - target
                    temp = (vel + omega * change) * dt
                    new_vel = (vel - omega * temp) * exp
                    new_cur = target + (change + temp) * exp

                    if abs(target - new_cur) < 0.05 and abs(new_vel) < 0.2:
                        new_cur = target
                        new_vel = 0.0
                    else:
                        still_animating = True

                    job["cur_pct"] = new_cur
                    job["velocity"] = new_vel
                    if not needs_full_redraw:
                        self._update_job_pbar(iid, new_cur)
                elif cur != target:
                    job["cur_pct"] = target
                    job["velocity"] = 0.0
                    if not needs_full_redraw:
                        self._update_job_pbar(iid, target)

            if job.get("is_done_ui") and "metrics_fade_start" in job:
                try:
                    elapsed_mf = now - job["metrics_fade_start"]
                    mf_dur = 0.40
                    mf_p = min(1.0, max(0.0, elapsed_mf / mf_dur))
                    if mf_p < 1.0:
                        still_animating = True
                    card_alpha = job.get("alpha", 1.0)
                    if mf_p <= 0.40:
                        fade_alpha = max(0.0, 1.0 - (mf_p / 0.40))
                        cur_txt = job.get("old_metrics", "")
                    else:
                        fade_alpha = min(1.0, (mf_p - 0.40) / 0.60)
                        cur_txt = job.get("done_metrics", "Completed")
                    eff_alpha = fade_alpha * card_alpha
                    txt_col = blend_hex("#9ea8ad", DONE_BG, eff_alpha)
                    self.itemconfig(f"metrics_{iid}", text=cur_txt, fill=txt_col)
                    if not needs_full_redraw:
                        pct_col = blend_hex(DONE_GREEN, CARD_BG, card_alpha)
                        self.itemconfig(f"pct_{iid}", text="100%", fill=pct_col)
                except tk.TclError:
                    pass

        if dead_ids:
            for di in dead_ids:
                self.jobs.pop(di, None)
                if di in self.job_order:
                    self.job_order.remove(di)
            needs_full_redraw = True
            if self.on_layout_needed:
                try: self.on_layout_needed()
                except Exception: pass

        if needs_full_redraw:
            self.redraw_all()

        if still_animating:
            self._anim_job = self.after(12, self._tween_step)

    def _update_job_pbar(self, item_id, pct):
        job = self.jobs.get(item_id)
        if not job or "bounds" not in job: return
        x1, y1, x2, y2 = job["bounds"]
        w = x2 - x1
        fill_x = x1 + max(0.0, min(w, w * (pct / 100.0)))
        card_h = y2 - y1
        rad = max(1.0, min(8.0, card_h / 2.0))
        pts, stroke_w = self._get_progress_rect_params(x1, y1, x2, y2, fill_x, radius=rad)
        tag = f"pbar_fill_{item_id}"
        if not pts:
            try:
                self.itemconfigure(tag, state="hidden")
            except tk.TclError:
                pass
            return
        try:
            is_done = job.get("is_complete", False) or job.get("is_done_ui", False) or (pct >= 99.95)
            alpha = job.get("alpha", 1.0)
            p_col = blend_hex(DONE_BG, CARD_BG, alpha) if is_done else blend_hex(self._get_progress_color(), CARD_BG, alpha)
            if not self.find_withtag(tag):
                self.create_polygon(
                    pts, fill=p_col, outline=p_col, width=stroke_w,
                    joinstyle=tk.ROUND, state="normal",
                    tags=("pbar_fill", tag)
                )
                if self.find_withtag(f"card_{item_id}"):
                    self.tag_raise(tag, f"card_{item_id}")
                for text_tag in (f"title_{item_id}", f"metrics_{item_id}", f"pct_{item_id}"):
                    if self.find_withtag(text_tag):
                        self.tag_raise(text_tag)
            else:
                self.coords(tag, *pts)
                self.itemconfigure(tag, fill=p_col, outline=p_col, width=stroke_w, joinstyle=tk.ROUND, state="normal")
        except tk.TclError:
            pass

    def start_job(self, item_id, display_title, tag):
        if item_id not in self.jobs:
            self.job_order.append(item_id)
        self.jobs[item_id] = {
            "id": item_id, "title": display_title, "tag": tag,
            "target_pct": 0.0, "cur_pct": 0.0, "velocity": 0.0,
            "t_str": "00:00 / --:--", "s_str": "0.0x", "f_str": "0 fps", "eta_str": "ETA: --:--",
            "state": "active", "alpha": 1.0, "height_factor": 1.0, "is_complete": False
        }
        self.redraw_all()

    def update_progress(self, item_id, pct, t_str, s_str, f_str, eta_str):
        job = self.jobs.get(item_id)
        if not job or job.get("state") in ("holding", "fading", "dead"): return
        clean_t = t_str.replace("Time: ", "").strip()
        clean_s = s_str.replace("Speed: ", "").strip()
        clean_f = f_str.replace("FPS: ", "").strip() + (" fps" if not f_str.endswith("fps") else "")
        target_p = max(0.0, min(100.0, float(pct)))
        job.update({
            "target_pct": target_p,
            "t_str": clean_t, "s_str": clean_s, "f_str": clean_f, "eta_str": eta_str
        })
        if target_p < job.get("cur_pct", 0.0) - 4.0:
            job["cur_pct"] = target_p
            job["velocity"] = 0.0
            self._update_job_pbar(item_id, target_p)
        if target_p >= 99.95:
            target_p = 100.0
            job["target_pct"] = 100.0
            job["is_done_ui"] = True
            if "metrics_fade_start" not in job:
                job["metrics_fade_start"] = time.perf_counter()
                job["old_metrics"] = f"{clean_t}  •  {clean_s}  •  {clean_f}  •  {eta_str}"
                job["done_metrics"] = f"{clean_t}  •  Completed" if clean_t else "Completed"
            self.itemconfig(f"pct_{item_id}", text="100%", fill=DONE_GREEN)
            self._update_job_pbar(item_id, 100.0)
        else:
            self.itemconfig(f"pct_{item_id}", text=f"{pct:.1f}%", fill=ULTRA_TEXT)
            metrics_txt = f"{clean_t}  •  {clean_s}  •  {clean_f}  •  {eta_str}"
            self.itemconfig(f"metrics_{item_id}", text=metrics_txt)
        self._start_tween()

    def end_job(self, item_id, completed=True):
        job = self.jobs.get(item_id)
        if not job:
            if item_id in self.job_order:
                self.job_order.remove(item_id)
            self.redraw_all()
            return

        if job.get("state") in ("holding", "fading", "dead"):
            return

        now = time.perf_counter()
        if completed:
            job["is_complete"] = True
            job["is_done_ui"] = True
            job["target_pct"] = 100.0
            job["cur_pct"] = 100.0
            if "metrics_fade_start" not in job:
                job["metrics_fade_start"] = now
                clean_t = job.get("t_str", "")
                clean_s = job.get("s_str", "")
                clean_f = job.get("f_str", "")
                clean_eta = job.get("eta_str", "")
                job["old_metrics"] = f"{clean_t}  •  {clean_s}  •  {clean_f}  •  {clean_eta}" if (clean_s or clean_f) else (f"{clean_t}  •  Completed" if clean_t else "Completed")
                job["done_metrics"] = f"{clean_t}  •  Completed" if clean_t else "Completed"
            job["state"] = "holding"
            job["hold_start"] = now
            job["hold_duration"] = 0.85
            job["exit_duration"] = 0.38
        else:
            job["state"] = "fading"
            job["fade_start"] = now
            job["exit_duration"] = 0.18

        self.redraw_all()
        self._start_tween()

    def job_count(self):
        return len([iid for iid in self.job_order if self.jobs.get(iid, {}).get("state") != "dead"])

    def _draw_rounded_rect(self, x1, y1, x2, y2, radius=8, **kwargs):
        r = max(1.0, min(float(radius), (x2 - x1) / 2.0, (y2 - y1) / 2.0))
        fill_col = kwargs.get("fill")
        border_col = kwargs.get("outline")
        border_w = max(1, int(round(float(kwargs.get("width", 1.0) or 1.0))))
        tags = kwargs.get("tags")

        has_border = bool(border_col and border_col != "" and border_col != fill_col and border_w > 0)

        if has_border:
            cx1, cy1 = x1 + r, y1 + r
            cx2, cy2 = x2 - r, y2 - r
            if cx2 < cx1:
                cx1 = cx2 = (x1 + x2) / 2.0
            if cy2 < cy1:
                cy1 = cy2 = (y1 + y2) / 2.0
            self.create_polygon(
                cx1, cy1, cx2, cy1, cx2, cy2, cx1, cy2,
                fill=border_col, outline=border_col, width=r * 2.0,
                joinstyle=tk.ROUND, tags=tags
            )

            inner_r = max(0.5, r - border_w)
            bw = r - inner_r
            ix1, iy1 = x1 + bw, y1 + bw
            ix2, iy2 = x2 - bw, y2 - bw
            icx1, icy1 = ix1 + inner_r, iy1 + inner_r
            icx2, icy2 = ix2 - inner_r, iy2 - inner_r
            if icx2 < icx1:
                icx1 = icx2 = (ix1 + ix2) / 2.0
            if icy2 < icy1:
                icy1 = icy2 = (iy1 + icy2) / 2.0
            return self.create_polygon(
                icx1, icy1, icx2, icy1, icx2, icy2, icx1, icy2,
                fill=fill_col, outline=fill_col, width=inner_r * 2.0,
                joinstyle=tk.ROUND, tags=tags
            )
        else:
            col = fill_col or border_col or "#000000"
            cx1, cy1 = x1 + r, y1 + r
            cx2, cy2 = x2 - r, y2 - r
            if cx2 < cx1:
                cx1 = cx2 = (x1 + x2) / 2.0
            if cy2 < cy1:
                cy1 = cy2 = (y1 + y2) / 2.0
            return self.create_polygon(
                cx1, cy1, cx2, cy1, cx2, cy2, cx1, cy2,
                fill=col, outline=col, width=r * 2.0,
                joinstyle=tk.ROUND, tags=tags
            )

    def redraw_all(self):
        self.delete("all")
        w = max(200, self.winfo_width())
        total_items = len(self.job_order)
        content_h = sum(self.ROW_STEP * self.jobs.get(iid, {}).get("height_factor", 1.0) for iid in self.job_order)
        total_h = max(1, int(round(content_h)) + 4)
        self.configure(scrollregion=(0, 0, w, total_h))
        if total_items == 0:
            try: ch = float(self.cget("height"))
            except Exception: ch = 40.0
            h = max(ch, float(self.winfo_height()))
            self.create_text(w / 2, h / 2, text="No active encodes", fill=TEXT_MUTED, font=("SF Pro Text", 11), tags="placeholder")
            if not self.scroller.is_animating:
                self.scroller.sync_position()
            return

        base_p_col = self._get_progress_color()
        cur_y = 3.0

        for iid in list(self.job_order):
            job = self.jobs.get(iid)
            if not job: continue

            h_factor = job.get("height_factor", 1.0)
            if h_factor <= 0.005:
                continue

            alpha = job.get("alpha", 1.0)
            card_h = self.CARD_H * h_factor
            y1 = cur_y
            y2 = y1 + card_h
            x1, x2 = 4, w - 4
            job["bounds"] = (x1, y1, x2, y2)
            cur_y += self.ROW_STEP * h_factor

            cur_pct = job.get("cur_pct", 0.0)
            target_pct = job.get("target_pct", 0.0)

            bg_target = CARD_BG
            sh1_col = blend_hex("#090a0d", bg_target, alpha)
            sh2_col = blend_hex("#07080a", bg_target, alpha)
            sh3_col = blend_hex("#050507", bg_target, alpha)
            card_bg = blend_hex("#161616", bg_target, alpha)

            is_comp = job.get("is_complete", False) or job.get("is_done_ui", False) or (cur_pct >= 99.95) or (target_pct >= 99.95)
            if is_comp:
                p_col = blend_hex(DONE_BG, bg_target, alpha)
            else:
                p_col = blend_hex(base_p_col, bg_target, alpha)

            rad = max(1.0, min(8.0, card_h / 2.0))

            # 1. Drop shadows
            if alpha > 0.08 and card_h > 8:
                self._draw_rounded_rect(x1 - 1, y1 + 1, x2 + 1, y2 + 3, radius=rad, fill=sh1_col, outline="", tags=("shadow", f"shadow_{iid}"))
                self._draw_rounded_rect(x1, y1 + 1, x2, y2 + 2, radius=rad, fill=sh2_col, outline="", tags=("shadow", f"shadow_{iid}"))
                self._draw_rounded_rect(x1, y1 + 1, x2, y2 + 1, radius=rad, fill=sh3_col, outline="", tags=("shadow", f"shadow_{iid}"))

            # 2. Card base background
            self._draw_rounded_rect(x1, y1, x2, y2, radius=rad, fill=card_bg, outline="", width=0, tags=("card", f"card_{iid}"))

            # 3. Full-width faded progress fill BEHIND text
            fill_x = x1 + (x2 - x1) * (cur_pct / 100.0)
            pts, stroke_w = self._get_progress_rect_params(x1, y1, x2, y2, fill_x, radius=rad)
            dummy_pts = [x1, y1, x1, y1, x1, y1, x1, y1]
            self.create_polygon(
                pts if pts else dummy_pts,
                fill=p_col, outline=p_col,
                width=stroke_w if pts else 0,
                joinstyle=tk.ROUND,
                state="normal" if pts else "hidden",
                tags=("pbar_fill", f"pbar_fill_{iid}")
            )

            # 4. Text & Metrics drawn on top, vertically centered
            if alpha > 0.12 and card_h > 12:
                tag_str = f"[{job['tag']}] " if job.get("tag") else ""
                raw_title = f"{tag_str}{job['title']}"
                disp_pct = job.get("target_pct", cur_pct)
                cy = (y1 + y2) / 2

                pct_col_raw = DONE_GREEN if is_comp else ULTRA_TEXT
                pct_col = blend_hex(pct_col_raw, bg_target, alpha)
                pct_x = x2 - 12
                metrics_x = pct_x - 52
                disp_pct_str = "100%" if (is_comp or disp_pct >= 99.95) else f"{disp_pct:.1f}%"
                self.create_text(pct_x, cy, text=disp_pct_str, fill=pct_col, anchor="e", font=("SF Pro Text", 10, "bold"), tags=("pct", f"pct_{iid}"))

                if is_comp:
                    if "metrics_fade_start" in job:
                        elapsed_mf = time.perf_counter() - job["metrics_fade_start"]
                        mf_p = min(1.0, max(0.0, elapsed_mf / 0.40))
                        if mf_p <= 0.40:
                            fade_alpha = max(0.0, 1.0 - (mf_p / 0.40))
                            metrics_txt = job.get("old_metrics", "")
                        else:
                            fade_alpha = min(1.0, (mf_p - 0.40) / 0.60)
                            metrics_txt = job.get("done_metrics", "Completed")
                        metrics_col = blend_hex(blend_hex("#9ea8ad", DONE_BG, fade_alpha), bg_target, alpha)
                    else:
                        clean_t = job.get("t_str", "")
                        metrics_txt = f"{clean_t}  •  Completed" if clean_t else "Completed"
                        metrics_col = blend_hex("#9ea8ad", bg_target, alpha)
                else:
                    metrics_txt = f"{job.get('t_str')}  •  {job.get('s_str')}  •  {job.get('f_str')}  •  {job.get('eta_str')}"
                    metrics_col = blend_hex("#9ea8ad", bg_target, alpha)
                self.create_text(metrics_x, cy, text=metrics_txt, fill=metrics_col, anchor="e", font=("SF Mono", 9), tags=("metrics", f"metrics_{iid}"))

                title_col = blend_hex(TEXT_PRIMARY, bg_target, alpha)
                avail_w = max(60, (metrics_x - 10) - (x1 + 12) - 150)
                max_chars = max(10, int(avail_w / 7.2))
                disp_title = raw_title[:max_chars - 3] + "..." if len(raw_title) > max_chars else raw_title
                self.create_text(x1 + 12, cy, text=disp_title, fill=title_col, anchor="w", font=("SF Pro Text", 10, "bold"), tags=("title", f"title_{iid}"))

        if not self.scroller.is_animating:
            self.scroller.sync_position()

    def _on_resize(self, event):
        self.redraw_all()


class QuartzQueueCanvas(tk.Canvas):
    ROW_H = 36
    ROW_GAP = 4
    ROW_STEP = 40

    def __init__(self, master, on_remove_item=None, on_inspect_item=None, on_select_item=None, **kwargs):
        super().__init__(master, bg=CARD_BG, bd=0, highlightthickness=0, relief="flat", **kwargs)
        self.on_remove_item = on_remove_item
        self.on_inspect_item = on_inspect_item
        self.on_select_item = on_select_item
        self.selected_ids = set()
        self.items = []
        self.item_map = {}
        self.rendered_rows = {}  # maps idx -> item_id
        self.is_option_mode = False
        self._external_yscrollcommand = None
        self._updating_viewport = False

        self.scroller = QuartzKineticScroller(
            get_view_metrics=self._get_scroll_metrics,
            set_view_fraction=self.yview_moveto,
            after_fn=self.after,
            cancel_after_fn=self.after_cancel
        )
        self.hovered_del_id = None
        self.hovered_info_id = None
        self.bind("<Configure>", self._on_resize)
        self.bind("<Motion>", self._on_mouse_move)
        self.bind("<Leave>", self._on_mouse_leave)
        self.bind("<Button-1>", self._on_click)

    def configure(self, cnf=None, **kwargs):
        if "yscrollcommand" in kwargs:
            self._external_yscrollcommand = kwargs.pop("yscrollcommand")
            kwargs["yscrollcommand"] = self._on_scroll_notify
        return super().configure(cnf, **kwargs)

    config = configure

    def _on_scroll_notify(self, first, last):
        if self._external_yscrollcommand:
            try:
                self._external_yscrollcommand(first, last)
            except Exception:
                pass
        if not self._updating_viewport:
            self._update_visible_rows()

    def yview(self, *args):
        res = super().yview(*args)
        if args and not self._updating_viewport:
            self._update_visible_rows()
        return res

    def yview_moveto(self, fraction):
        res = super().yview_moveto(fraction)
        if not self._updating_viewport:
            self._update_visible_rows()
        return res

    def _get_scroll_metrics(self):
        sr = self.cget("scrollregion")
        if not sr: return None
        try:
            parts = [float(p) for p in str(sr).split()]
            total_h = parts[3] - parts[1]
        except Exception:
            return None
        view_h = float(self.winfo_height())
        if total_h <= 0 or view_h <= 0: return None
        return (view_h, total_h, self.yview()[0])

    def handle_wheel_input(self, delta_input):
        self.scroller.handle_wheel_input(delta_input)

    def set_option_mode(self, enabled):
        if getattr(self, "is_option_mode", False) != enabled:
            self.is_option_mode = enabled
            if len(self.items) == 0 and self.find_withtag("placeholder"):
                txt = "Drop a file to inspect metadata" if enabled else "Drop files or folders anywhere to start encode"
                self.itemconfig("placeholder", text=txt)

    def set_items(self, items):
        self.items = list(items)
        self.item_map = {x["id"]: x for x in self.items}
        self.redraw_all()

    def set_selected_ids(self, ids):
        new_sel = set(ids) if ids else set()
        old_sel = getattr(self, "selected_ids", set())
        self.selected_ids = new_sel
        changed_ids = old_sel ^ new_sel
        if not changed_ids:
            return
        rendered_id_set = set(self.rendered_rows.values())
        for iid in changed_ids:
            if iid in rendered_id_set:
                self._redraw_row(iid)

    def _redraw_row(self, item_id):
        idx = next((i for i, it in enumerate(self.items) if it["id"] == item_id), None)
        if idx is not None and idx in self.rendered_rows:
            self.delete(f"row_item_{item_id}")
            w = max(200, self.winfo_width())
            self._draw_row(idx, self.items[idx], w)
            self.rendered_rows[idx] = item_id

    def update_item_status(self, item_id, status, ptext=None, done_stats=None):
        item = self.item_map.get(item_id)
        if not item: return
        item["status"] = status
        if ptext is not None: item["progress_text"] = ptext
        if done_stats is not None: item["done_stats"] = done_stats
        self._redraw_row(item_id)

    def _get_visible_range(self):
        total_items = len(self.items)
        if total_items == 0:
            return -1, -1
        view_h = float(self.winfo_height())
        if view_h <= 1:
            try:
                view_h = float(self.cget("height"))
            except Exception:
                view_h = 400.0
        y_top = self.canvasy(0)
        y_bot = self.canvasy(view_h)
        start_idx = max(0, int((y_top - 4) // self.ROW_STEP) - 3)
        end_idx = min(total_items - 1, int((y_bot - 4) // self.ROW_STEP) + 3)
        return start_idx, end_idx

    def _update_visible_rows(self, force=False):
        if self._updating_viewport:
            return
        self._updating_viewport = True
        try:
            total_items = len(self.items)
            w = max(200, self.winfo_width())
            total_h = max(1, total_items * self.ROW_STEP + 8)

            sr = (0, 0, w, total_h)
            cur_sr = self.cget("scrollregion")
            if not cur_sr or str(cur_sr) != f"0 0 {w} {total_h}":
                self.configure(scrollregion=sr)

            if total_items == 0:
                self.delete("all")
                self.rendered_rows.clear()
                h = max(100, self.winfo_height())
                placeholder_text = "Drop a file to inspect metadata" if getattr(self, "is_option_mode", False) else "Drop files or folders anywhere to start encode"
                self.create_text(w / 2, h / 2, text=placeholder_text, fill=TEXT_MUTED, font=("SF Pro Text", 11), tags="placeholder")
                if not self.scroller.is_animating:
                    self.scroller.sync_position()
                return

            self.delete("placeholder")

            start_idx, end_idx = self._get_visible_range()
            if start_idx < 0:
                return

            needed_indices = set(range(start_idx, end_idx + 1))

            if force:
                for iid in list(self.rendered_rows.values()):
                    self.delete(f"row_item_{iid}")
                self.rendered_rows.clear()

            for idx in list(self.rendered_rows.keys()):
                if idx not in needed_indices:
                    iid = self.rendered_rows.pop(idx)
                    self.delete(f"row_item_{iid}")
                elif not force and idx < len(self.items):
                    item = self.items[idx]
                    if self.rendered_rows[idx] != item["id"]:
                        old_iid = self.rendered_rows.pop(idx)
                        self.delete(f"row_item_{old_iid}")

            for idx in range(start_idx, end_idx + 1):
                if idx not in self.rendered_rows and idx < len(self.items):
                    item = self.items[idx]
                    self._draw_row(idx, item, w)
                    self.rendered_rows[idx] = item["id"]

            if not self.scroller.is_animating:
                self.scroller.sync_position()
        finally:
            self._updating_viewport = False

    def redraw_all(self):
        self._update_visible_rows(force=True)

    def _draw_row(self, idx, item, w):
        iid = item["id"]
        y1 = idx * self.ROW_STEP + 4
        y2 = y1 + self.ROW_H
        x1, x2 = 6, w - 6

        is_sel = (iid in getattr(self, "selected_ids", set()))
        row_fill = ULTRA_BG if is_sel else "#161616"
        row_outline = ULTRA_TEXT if is_sel else ""
        row_width = 1.5 if is_sel else 0

        self._draw_rounded_rect(x1 - 1, y1 + 1, x2 + 1, y2 + 3, radius=9, fill="#090a0d", outline="", tags=("shadow", f"shadow_{iid}", f"row_item_{iid}"))
        self._draw_rounded_rect(x1, y1 + 1, x2, y2 + 2, radius=8, fill="#07080a", outline="", tags=("shadow", f"shadow_{iid}", f"row_item_{iid}"))
        self._draw_rounded_rect(x1, y1 + 1, x2, y2 + 1, radius=8, fill="#050507", outline="", tags=("shadow", f"shadow_{iid}", f"row_item_{iid}"))
        self._draw_rounded_rect(x1, y1, x2, y2, radius=8, fill=row_fill, outline=row_outline, width=row_width, tags=("row", f"row_{iid}", f"row_item_{iid}"))

        status = item.get("status", "queued")
        btn_cy = (y1 + y2) / 2
        b_w, b_h = 95, 22
        b_x2 = x2 - 10
        b_x1 = b_x2 - b_w
        b_y1, b_y2 = btn_cy - (b_h / 2), btn_cy + (b_h / 2)

        pt = item.get("progress_text")
        if status == "encoding": bg_col, out_col, txt_col, txt = ULTRA_BG, ULTRA_BORDER, ULTRA_TEXT, (f"ENCODING {pt}" if pt else "ENCODING")
        elif status == "suspended": bg_col, out_col, txt_col, txt = HOLD_BG, HOLD_BORDER, HOLD_TEXT, (f"ON HOLD {pt}" if pt else "ON HOLD")
        elif status == "completed": bg_col, out_col, txt_col, txt = DONE_BG, DONE_BORDER, DONE_GREEN, "DONE"
        elif status == "failed": bg_col, out_col, txt_col, txt = "#450a0a", "#7f1d1d", "#f87171", "FAILED"
        elif status == "cancelled": bg_col, out_col, txt_col, txt = HOLD_BG, HOLD_BORDER, HOLD_TEXT, "SKIPPED"
        elif is_sel: bg_col, out_col, txt_col, txt = ULTRA_BG, ULTRA_BORDER, ULTRA_TEXT, "SELECTED"
        else: bg_col, out_col, txt_col, txt = "#1c1c1c", "#2a2a2a", "#858585", "QUEUED"

        self._draw_rounded_rect(b_x1, b_y1, b_x2, b_y2, radius=6, fill=bg_col, outline=out_col, width=1, tags=("badge_bg", f"badge_bg_{iid}", f"row_item_{iid}"))
        self.create_text((b_x1 + b_x2) / 2, (b_y1 + b_y2) / 2, text=txt, fill=txt_col, font=("SF Pro Text", 9, "bold"), tags=("badge_txt", f"badge_txt_{iid}", f"row_item_{iid}"))

        info_cx = b_x1 - 18
        left_cx = info_cx
        if status not in ("completed", "failed", "cancelled"):
            btn_cx = info_cx - 28
            left_cx = btn_cx
            is_del_h = (iid == self.hovered_del_id)
            del_bg = "#450a0a" if is_del_h else "#1c1c1c"
            del_out = "#7f1d1d" if is_del_h else ""
            del_fg = "#f87171" if is_del_h else "#707070"
            self.create_oval(btn_cx - 11, btn_cy - 11, btn_cx + 11, btn_cy + 11, fill=del_bg, outline=del_out, width=1, tags=("del_btn", f"del_btn_{iid}", f"row_item_{iid}"))
            self.create_text(btn_cx + 1, btn_cy, text="✕", fill=del_fg, font=("SF Pro Text", 10, "bold"), tags=("del_txt", f"del_txt_{iid}", f"row_item_{iid}"))

        is_info_h = (iid == self.hovered_info_id)
        info_bg = ULTRA_BG if is_info_h else "#1c1c1c"
        info_out = ULTRA_BORDER if is_info_h else ""
        info_fg = ULTRA_TEXT if is_info_h else "#707070"
        self.create_oval(info_cx - 11, btn_cy - 11, info_cx + 11, btn_cy + 11, fill=info_bg, outline=info_out, width=1, tags=("info_btn", f"info_btn_{iid}", f"row_item_{iid}"))
        self.create_text(info_cx + 1, btn_cy + 1, text="i", fill=info_fg, font=("SF Pro Text", 11, "bold"), tags=("info_txt", f"info_txt_{iid}", f"row_item_{iid}"))

        st = item.get("settings", {})
        s_parts = []
        if st:
            c_raw = st.get("codec", "HEVC")
            c_name = "HEVC" if "HEVC" in c_raw else ("H.264" if "H.264" in c_raw else c_raw)
            enc = st.get("encoder", "")
            s_parts.append(f"{c_name} (CPU)" if enc == "CPU" else c_name)
            if st.get("chroma"):
                s_parts.append(st["chroma"])
            q = st.get("quality")
            if q is not None:
                try:
                    q_int = int(q)
                    q_enc = st.get("quality_encoder", enc)
                    if enc == "AppleMediaEngine":
                        vt_q = max(1, min(100, int(round((q_int / 51.0) * 100)))) if q_enc == "CPU" and q_int <= 51 else q_int
                        s_parts.append(f"Q{vt_q}")
                    else:
                        cpu_q = int(round((q_int / 100.0) * 51)) if (q_enc == "AppleMediaEngine" or q_int > 51) else q_int
                        crf_disp = max(0, min(51, 51 - cpu_q))
                        s_parts.append(f"CRF {crf_disp}")
                except Exception:
                    pass
            try:
                d_raw = float(st.get("denoise", 0) or 0)
                d_int = int(round(d_raw * 1000)) if 0.0 < d_raw < 1.0 else int(round(d_raw))
            except Exception:
                d_int = 0
            if d_int > 0:
                s_parts.append(f"DN {d_int}")
        settings_str = " • ".join(s_parts)

        done_str = item.get("done_stats", "")
        raw_name = item.get("display_name", item.get("filename", ""))
        avail_w = max(40, (left_cx - 16) - (x1 + 12))
        settings_w = int(len(settings_str) * 6.0) if settings_str else 0
        done_w = int(len(done_str) * 6.0) if done_str else 0
        gap = 10 if (settings_str or done_str) else 0
        max_name_w = max(80, avail_w - settings_w - done_w - (gap * 2))
        max_name_chars = max(8, int(max_name_w / 7.2))
        disp_name = raw_name[:max_name_chars - 3] + "..." if len(raw_name) > max_name_chars else raw_name

        t_name = self.create_text(x1 + 12, (y1 + y2) / 2, text=disp_name, fill=TEXT_PRIMARY, anchor="w", font=("SF Pro Text", 11), tags=("title", f"title_{iid}", f"row_item_{iid}"))

        cur_x = (self.bbox(t_name)[2] + gap) if self.bbox(t_name) else (x1 + 12 + int(len(disp_name) * 7.2) + gap)

        if settings_str:
            rem_w = max(10, (left_cx - 12 - done_w - (gap if done_str else 0)) - cur_x)
            max_s_chars = max(5, int(rem_w / 6.0))
            disp_settings = settings_str[:max_s_chars - 3] + "..." if len(settings_str) > max_s_chars else settings_str
            if rem_w >= 20:
                t_set = self.create_text(cur_x, (y1 + y2) / 2, text=disp_settings, fill=TEXT_MUTED, anchor="w", font=("SF Pro Text", 10), tags=("settings", f"settings_{iid}", f"row_item_{iid}"))
                cur_x = (self.bbox(t_set)[2] + gap) if self.bbox(t_set) else (cur_x + int(len(disp_settings) * 6.0) + gap)

        if done_str:
            rem_w = max(10, (left_cx - 12) - cur_x)
            max_d_chars = max(5, int(rem_w / 6.0))
            disp_done = done_str[:max_d_chars - 3] + "..." if len(done_str) > max_d_chars else done_str
            if rem_w >= 20:
                self.create_text(cur_x, (y1 + y2) / 2, text=disp_done, fill=DONE_GREEN, anchor="w", font=("SF Pro Text", 10), tags=("done_stats", f"done_stats_{iid}", f"row_item_{iid}"))

    def _draw_rounded_rect(self, x1, y1, x2, y2, radius=8, **kwargs):
        r = max(1.0, min(float(radius), (x2 - x1) / 2.0, (y2 - y1) / 2.0))
        fill_col = kwargs.get("fill")
        border_col = kwargs.get("outline")
        border_w = max(1, int(round(float(kwargs.get("width", 1.0) or 1.0))))
        tags = kwargs.get("tags")

        has_border = bool(border_col and border_col != "" and border_col != fill_col and border_w > 0)

        if has_border:
            cx1, cy1 = x1 + r, y1 + r
            cx2, cy2 = x2 - r, y2 - r
            if cx2 < cx1:
                cx1 = cx2 = (x1 + x2) / 2.0
            if cy2 < cy1:
                cy1 = cy2 = (y1 + y2) / 2.0
            self.create_polygon(
                cx1, cy1, cx2, cy1, cx2, cy2, cx1, cy2,
                fill=border_col, outline=border_col, width=r * 2.0,
                joinstyle=tk.ROUND, tags=tags
            )

            inner_r = max(0.5, r - border_w)
            bw = r - inner_r
            ix1, iy1 = x1 + bw, y1 + bw
            ix2, iy2 = x2 - bw, y2 - bw
            icx1, icy1 = ix1 + inner_r, iy1 + inner_r
            icx2, icy2 = ix2 - inner_r, iy2 - inner_r
            if icx2 < icx1:
                icx1 = icx2 = (ix1 + ix2) / 2.0
            if icy2 < icy1:
                icy1 = icy2 = (iy1 + icy2) / 2.0
            return self.create_polygon(
                icx1, icy1, icx2, icy1, icx2, icy2, icx1, icy2,
                fill=fill_col, outline=fill_col, width=inner_r * 2.0,
                joinstyle=tk.ROUND, tags=tags
            )
        else:
            col = fill_col or border_col or "#000000"
            cx1, cy1 = x1 + r, y1 + r
            cx2, cy2 = x2 - r, y2 - r
            if cx2 < cx1:
                cx1 = cx2 = (x1 + x2) / 2.0
            if cy2 < cy1:
                cy1 = cy2 = (y1 + y2) / 2.0
            return self.create_polygon(
                cx1, cy1, cx2, cy1, cx2, cy2, cx1, cy2,
                fill=col, outline=col, width=r * 2.0,
                joinstyle=tk.ROUND, tags=tags
            )

    def _on_resize(self, event):
        self.redraw_all()

    def _get_target_action(self, canvas_x, canvas_y):
        idx = int((canvas_y - 4) // self.ROW_STEP)
        if 0 <= idx < len(self.items):
            item = self.items[idx]
            status = item.get("status", "queued")
            is_finished = status in ("completed", "failed", "cancelled")
            w = max(200, self.winfo_width())
            x2 = w - 6
            b_x1 = (x2 - 10) - 95
            y1 = idx * self.ROW_STEP + 4
            btn_cy = (y1 + y1 + self.ROW_H) / 2
            info_cx = b_x1 - 18
            if not is_finished:
                btn_cx = info_cx - 28
                if (canvas_x - btn_cx) ** 2 + (canvas_y - btn_cy) ** 2 <= 14 * 14:
                    return "delete", item["id"]
            if (canvas_x - info_cx) ** 2 + (canvas_y - btn_cy) ** 2 <= 14 * 14:
                return "info", item["id"]
            return "select", item["id"]
        return None, None

    def _on_mouse_move(self, event):
        cx, cy = self.canvasx(event.x), self.canvasy(event.y)
        action, target_id = self._get_target_action(cx, cy)
        self.configure(cursor="hand2" if action in ("delete", "info") else "")

        if action == "delete" and target_id != self.hovered_del_id:
            if self.hovered_del_id:
                self.itemconfig(f"del_btn_{self.hovered_del_id}", fill="#1c1c1c", outline="")
                self.itemconfig(f"del_txt_{self.hovered_del_id}", fill="#707070")
            self.hovered_del_id = target_id
            self.itemconfig(f"del_btn_{target_id}", fill="#450a0a", outline="#7f1d1d")
            self.itemconfig(f"del_txt_{target_id}", fill="#f87171")
        elif action != "delete" and self.hovered_del_id:
            self.itemconfig(f"del_btn_{self.hovered_del_id}", fill="#1c1c1c", outline="")
            self.itemconfig(f"del_txt_{self.hovered_del_id}", fill="#707070")
            self.hovered_del_id = None

        if action == "info" and target_id != self.hovered_info_id:
            if self.hovered_info_id:
                self.itemconfig(f"info_btn_{self.hovered_info_id}", fill="#1c1c1c", outline="")
                self.itemconfig(f"info_txt_{self.hovered_info_id}", fill="#707070")
            self.hovered_info_id = target_id
            self.itemconfig(f"info_btn_{target_id}", fill=ULTRA_BG, outline=ULTRA_BORDER)
            self.itemconfig(f"info_txt_{target_id}", fill=ULTRA_TEXT)
        elif action != "info" and self.hovered_info_id:
            self.itemconfig(f"info_btn_{self.hovered_info_id}", fill="#1c1c1c", outline="")
            self.itemconfig(f"info_txt_{self.hovered_info_id}", fill="#707070")
            self.hovered_info_id = None

    def _on_mouse_leave(self, event):
        self.configure(cursor="")
        if self.hovered_del_id:
            self.itemconfig(f"del_btn_{self.hovered_del_id}", fill="#1c1c1c", outline="")
            self.itemconfig(f"del_txt_{self.hovered_del_id}", fill="#707070")
            self.hovered_del_id = None
        if self.hovered_info_id:
            self.itemconfig(f"info_btn_{self.hovered_info_id}", fill="#1c1c1c", outline="")
            self.itemconfig(f"info_txt_{self.hovered_info_id}", fill="#707070")
            self.hovered_info_id = None

    def _on_click(self, event):
        self.focus_set()
        cx, cy = self.canvasx(event.x), self.canvasy(event.y)
        action, target_id = self._get_target_action(cx, cy)
        if action == "delete" and self.on_remove_item:
            self.on_remove_item(target_id)
        elif action == "info" and self.on_inspect_item:
            self.on_inspect_item(target_id)
        elif action == "select" and self.on_select_item:
            self.on_select_item(target_id, event)
        elif action is None and self.on_select_item:
            self.on_select_item(None, event)

# ============================================================
class UniversalScrollHandler:
    def __init__(self, root, queue_scroller=None, active_jobs_scroller=None, log_scroller=None, inspector_scroller=None,
                 queue_canvas=None, active_jobs_canvas=None, log_textbox=None, inspector_view=None):
        self.root = root
        self.queue_scroller = queue_scroller
        self.active_jobs_scroller = active_jobs_scroller
        self.log_scroller = log_scroller
        self.inspector_scroller = inspector_scroller
        self.queue_canvas = queue_canvas
        self.active_jobs_canvas = active_jobs_canvas
        self.log_textbox = log_textbox
        self.inspector_view = inspector_view
        self.manual_scroller = None
        self.manual_view = None

        for seq in ("<MouseWheel>", "<TouchpadScroll>", "<Button-4>", "<Button-5>"):
            try: self.root.unbind_class("Text", seq)
            except Exception: pass
            try: self.root.bind_all(seq, self._handle_scroll, add="+")
            except Exception: pass

    def _handle_scroll(self, event):
        try:
            raw_delta = getattr(event, "delta", 0)
            if getattr(event, "num", None) == 4: raw_delta = 1
            elif getattr(event, "num", None) == 5: raw_delta = -1
            if raw_delta == 0: return

            delta = float(raw_delta)
            x, y = getattr(event, "x_root", None), getattr(event, "y_root", None)
            if x is None or y is None:
                x, y = self.root.winfo_pointerxy()

            def is_inside(w):
                if not w or not w.winfo_ismapped(): return False
                try:
                    return (w.winfo_rootx() <= x <= w.winfo_rootx() + w.winfo_width()) and \
                           (w.winfo_rooty() <= y <= w.winfo_rooty() + w.winfo_height())
                except Exception: return False

            if is_inside(self.active_jobs_canvas):
                if self.active_jobs_scroller: self.active_jobs_scroller.handle_wheel_input(delta)
                return "break"
            if is_inside(self.queue_canvas):
                if self.queue_scroller: self.queue_scroller.handle_wheel_input(delta)
                return "break"
            if is_inside(self.log_textbox) or (hasattr(self.log_textbox, "_textbox") and is_inside(self.log_textbox._textbox)):
                if self.log_scroller: self.log_scroller.handle_wheel_input(delta)
                return "break"
            if is_inside(self.inspector_view) or (hasattr(self.inspector_view, "_textbox") and is_inside(self.inspector_view._textbox)):
                if self.inspector_scroller: self.inspector_scroller.handle_wheel_input(delta)
                return "break"
            if getattr(self, "manual_view", None) and (is_inside(self.manual_view) or (hasattr(self.manual_view, "_textbox") and is_inside(self.manual_view._textbox))):
                if getattr(self, "manual_scroller", None): self.manual_scroller.handle_wheel_input(delta)
                return "break"
        except Exception:
            pass

if HAS_TKDND:
    class CTkWithDnD(ctk.CTk, TkinterDnD.DnDWrapper):
        def __init__(self, *args, **kwargs):
            super().__init__(*args, **kwargs)
            try: self.TkdndVersion = TkinterDnD._require(self)
            except Exception as e: print(f"[WARNING] TkinterDnD init: {e}")
else:
    class CTkWithDnD(ctk.CTk):
        pass

class EncoderApp:
    def __init__(self, root, initial_files=None):
        global _GLOBAL_APP_INSTANCE
        _GLOBAL_APP_INSTANCE = self
        self.root = root
        self.root.title("MediaEngine")
        screen_w = self.root.winfo_screenwidth()
        screen_h = self.root.winfo_screenheight()
        win_w = 760
        win_h = min(960, max(680, screen_h - 100))
        pos_x = max(0, (screen_w - win_w) // 2)
        self.root.geometry(f"{win_w}x{win_h}+{pos_x}+0")
        self.root.minsize(680, 640)
        self.root.configure(fg_color=BG_MAIN)
        self.root.protocol("WM_DELETE_WINDOW", self.on_close)

        global HARDWARE_MEDIA_ENGINES, HARDWARE_CHIP_NAME
        HARDWARE_MEDIA_ENGINES, HARDWARE_CHIP_NAME = get_hardware_media_profile()
        self.engine_multiplier = HARDWARE_MEDIA_ENGINES
        self.chip_name = HARDWARE_CHIP_NAME
        self.current_encoder = "AppleMediaEngine"
        self.concurrency_mode = self.load_saved_concurrency()
        self.auto_start = self.load_saved_auto_start()
        self.tag_settings = self.load_saved_tag_settings()
        self.selected_queue_ids = set()
        self._selection_pivot_id = None
        self._loading_selection_settings = False
        self.settings_expanded = self.load_settings_expanded_state()
        self.batch_expanded = self.load_batch_expanded_state()
        self.active_jobs_height = self.load_saved_batch_height()
        self.presets = {}
        self.load_presets()

        self._preset_loading = False
        self.queue_lock = threading.RLock()
        self.process_lock = threading.RLock()
        self.ui_queue = queue.Queue()

        self.queue_items = []
        self.items_by_id = {}

        self.active_processes = {}
        self.running_ids = set()
        self.suspended_ids = set()
        self.cancelled_ids = set()
        self.retrying_ids = set()
        self.active_output_files = {}
        self.worker_threads = []
        self.hw_launch_lock = threading.Lock()
        self._last_hw_launch_time = 0.0
        self._last_hw_release_time = 0.0
        self._last_launch_time = 0.0
        self.last_pct_map = {}
        self.last_progress_map = {}
        self.item_counter = 0

        self.is_paused = False
        self.is_running = False
        self.dispatcher_alive = False
        self.cancel_requested = False
        self.active_scans = 0
        self.last_vt_quality = 69
        self.last_cpu_crf = 33
        self._dispatcher_crash_count = 0

        # Media Inspector Cache
        self.inspected_data = None
        self.inspected_path = None
        self.raw_json_mode = False
        self._startup_time = time.time()

        self.setup_ui()
        saved_preset = self.get_saved_preset_choice()
        self.preset_var.set(saved_preset)
        self.on_preset_change(saved_preset)
        self.setup_drag_and_drop()

        self.root.bind_all("<BackSpace>", self._on_delete_key, add="+")
        self.root.bind_all("<Delete>", self._on_delete_key, add="+")
        self.root.bind_all("<KP_Delete>", self._on_delete_key, add="+")

        self._option_key_pressed = False
        self.root.bind_all("<KeyPress>", self._on_key_press_option, add="+")
        self.root.bind_all("<KeyRelease>", self._on_key_release_option, add="+")
        self.root.after(60, self._poll_option_key)

        self.root.after(100, self.preflight_check)
        self.root.after(30, self._process_ui_queue)

        if initial_files:
            self.handle_incoming_files(initial_files)

    def load_saved_concurrency(self):
        try:
            if os.path.exists(CONCURRENCY_FILE):
                with open(CONCURRENCY_FILE, "r", encoding="utf-8") as f:
                    v = f.read().strip()
                    if v in ("Sequential", "Balanced", "Turbo"):
                        return v
                    elif v == "1":
                        return "Sequential"
                    elif v == "2":
                        return "Balanced"
                    elif v in ("3", "4"):
                        return "Turbo"
        except Exception: pass
        return "Balanced"

    def save_concurrency(self, val):
        try:
            os.makedirs(USER_PRESETS_DIR, exist_ok=True)
            with open(CONCURRENCY_FILE, "w", encoding="utf-8") as f:
                f.write(str(val))
        except Exception: pass

    def set_concurrency_mode(self, mode):
        if mode not in ("Sequential", "Balanced", "Turbo"):
            mode = "Balanced"
        self.concurrency_mode = mode
        self.save_concurrency(mode)
        self.update_concurrency_buttons_ui()
        self.rebalance_concurrency()
        self.update_active_jobs_layout()

    def update_concurrency_buttons_ui(self):
        cur = getattr(self, "concurrency_mode", "Balanced")
        buttons = [
            ("Sequential", getattr(self, "btn_parallel_seq", None)),
            ("Balanced", getattr(self, "btn_parallel_bal", None)),
            ("Turbo", getattr(self, "btn_parallel_turbo", None)),
        ]
        for name, btn in buttons:
            if not btn:
                continue
            if name == cur:
                btn.configure(
                    fg_color=ULTRA_BG,
                    hover_color=ULTRA_BG_HOVER,
                    text_color=ULTRA_TEXT,
                    border_width=1,
                    border_color=ULTRA_BORDER
                )
            else:
                btn.configure(
                    fg_color="#1a1a1a",
                    hover_color="#262626",
                    text_color=TEXT_MUTED,
                    border_width=0
                )

    def get_concurrency_budget(self, encoder=None):
        mode = getattr(self, "concurrency_mode", "Balanced")
        if encoder is None:
            encoder = getattr(self, "current_encoder", "AppleMediaEngine")
        if encoder == "CPU":
            return {"max_units": 2, "max_8k": 1, "max_jobs": 1 if mode == "Sequential" else 2}
        mult = getattr(self, "engine_multiplier", HARDWARE_MEDIA_ENGINES)
        if mode == "Sequential":
            return {"max_units": 4, "max_8k": 1, "max_jobs": 1}
        elif mode == "Balanced":
            jobs = max(2, mult * 2)
            return {"max_units": jobs * 2, "max_8k": mult, "max_jobs": jobs}
        else:  # Turbo
            ram_gb = getattr(self, "_total_ram_gb", None)
            if ram_gb is None:
                try:
                    ram_gb = (os.sysconf('SC_PAGE_SIZE') * os.sysconf('SC_PHYS_PAGES')) / (1024 ** 3)
                except Exception:
                    try:
                        res = subprocess.run(["sysctl", "-n", "hw.memsize"], capture_output=True, text=True, timeout=2)
                        ram_gb = int(res.stdout.strip()) / (1024 ** 3) if res.returncode == 0 else 16.0
                    except Exception:
                        ram_gb = 16.0
                self._total_ram_gb = ram_gb

            if mult <= 1 and ram_gb <= 8.5:
                return {"max_units": 4, "max_8k": 1, "max_jobs": 2}
            elif mult <= 1:
                return {"max_units": 4, "max_8k": 1, "max_jobs": 3}
            else:
                jobs = max(3, mult * 3)
                return {"max_units": jobs * 2, "max_8k": mult, "max_jobs": jobs}

    def rebalance_concurrency(self):
        with self.process_lock:
            active_enc = None
            with self.queue_lock:
                for rid in self.running_ids:
                    it = self.items_by_id.get(rid)
                    if it and it.get("settings", {}).get("encoder") == "CPU":
                        active_enc = "CPU"
                        break
            budget = self.get_concurrency_budget(encoder=active_enc)
            max_units = budget["max_units"]
            max_8k = budget["max_8k"]
            max_jobs = budget["max_jobs"]

            dead_ids = [iid for iid, p in list(self.active_processes.items()) if p.poll() is not None and iid not in self.retrying_ids]
            for di in dead_ids:
                if di not in self.running_ids:
                    self.active_processes.pop(di, None)
                    self.suspended_ids.discard(di)

            current_units = 0
            current_8k = 0
            with self.queue_lock:
                for rid in list(self.running_ids):
                    it = self.items_by_id.get(rid)
                    if it:
                        w, is8 = it.get("res_weight", 1), it.get("is_8k", False)
                        current_units += w
                        if is8:
                            current_8k += 1

            # 1. Suspend excess running jobs if budget is exceeded
            if len(self.running_ids) > 1:
                for rid in sorted(list(self.running_ids), reverse=True):
                    if len(self.running_ids) <= 1:
                        break
                    with self.queue_lock:
                        it = self.items_by_id.get(rid)
                        w, is8 = (it.get("res_weight", 1), it.get("is_8k", False)) if it else (1, False)
                    exceeds = (
                        (len(self.running_ids) > max_jobs) or
                        (current_units > max_units) or
                        (current_8k > max_8k)
                    )
                    if exceeds:
                        proc = self.active_processes.get(rid)
                        if proc and proc.poll() is None:
                            safe_killpg(proc, signal.SIGSTOP)
                        self.running_ids.discard(rid)
                        self.suspended_ids.add(rid)
                        current_units = max(0, current_units - w)
                        if is8:
                            current_8k = max(0, current_8k - 1)
                        self.ui_queue.put(("job_end", rid))
                        pct_val = int(self.last_pct_map.get(rid, 0))
                        self.update_item_status_ui(rid, "suspended", f"{pct_val}%", refresh_stats=True)

            # 2. Seamlessly resume suspended jobs if budget allows
            if self.suspended_ids and not self.is_paused:
                for wid in sorted(list(self.suspended_ids)):
                    with self.queue_lock:
                        it = self.items_by_id.get(wid)
                        if not it:
                            continue
                        w, is8 = it.get("res_weight", 1), it.get("is_8k", False)
                    fits = (current_units == 0) or (
                        (current_units + w <= max_units) and
                        (current_8k + (1 if is8 else 0) <= max_8k) and
                        (len(self.running_ids) < max_jobs)
                    )
                    if fits:
                        proc = self.active_processes.get(wid)
                        if proc and proc.poll() is None:
                            safe_killpg(proc, signal.SIGCONT)
                        self.suspended_ids.discard(wid)
                        self.running_ids.add(wid)
                        current_units += w
                        if is8:
                            current_8k += 1
                        disp_name = it.get("display_name", it.get("filename", f"Item #{wid}"))
                        c_tag = it.get("codec_tag", "HEVC")
                        self.ui_queue.put(("job_start", (wid, disp_name, c_tag)))
                        if wid in self.last_progress_map:
                            self.ui_queue.put(("progress", (wid, self.last_progress_map[wid])))
                        pct_val = int(self.last_pct_map.get(wid, 0))
                        self.update_item_status_ui(wid, "encoding", f"{pct_val}%", refresh_stats=True)
            return current_units, current_8k

    def load_saved_output_dir(self):
        default_dir = os.path.expanduser("~/Desktop")
        try:
            if os.path.exists(LAST_OUTPUT_DIR_FILE):
                with open(LAST_OUTPUT_DIR_FILE, "r", encoding="utf-8") as f:
                    saved = f.read().strip()
                    if saved and os.path.isdir(saved):
                        return saved
        except Exception: pass
        return default_dir

    def save_output_dir(self, path):
        try:
            clean_p = os.path.expanduser(str(path).strip())
            if os.path.isdir(clean_p):
                os.makedirs(USER_PRESETS_DIR, exist_ok=True)
                with open(LAST_OUTPUT_DIR_FILE, "w", encoding="utf-8") as f:
                    f.write(clean_p)
        except Exception: pass

    def load_settings_expanded_state(self):
        try:
            if os.path.exists(SETTINGS_STATE_FILE):
                with open(SETTINGS_STATE_FILE, "r", encoding="utf-8") as f:
                    return f.read().strip() != "0"
        except Exception: pass
        return True

    def draw_theme_dot(self):
        if not hasattr(self, "theme_dot"): return
        self.theme_dot.delete("all")
        self.theme_dot.create_arc(1, 1, 17, 17, start=90, extent=180, fill=ULTRA_BG, outline=ULTRA_BORDER, width=1)
        self.theme_dot.create_arc(1, 1, 17, 17, start=270, extent=180, fill=ULTRA_TEXT, outline=ULTRA_BORDER, width=1)

    def apply_theme_and_update(self, hex_code, save=True):
        apply_theme_colors(hex_code)
        if save:
            try:
                os.makedirs(USER_PRESETS_DIR, exist_ok=True)
                with open(THEME_FILE, "w", encoding="utf-8") as f:
                    f.write(hex_code)
            except Exception: pass
        else:
            try:
                if os.path.exists(THEME_FILE):
                    os.remove(THEME_FILE)
            except Exception: pass
        self.draw_theme_dot()
        if hasattr(self, "batch_progress_bar"):
            self.batch_progress_bar.configure(progress_color=ULTRA_TEXT)
        if hasattr(self, "quality_slider"):
            self.quality_slider.configure(progress_color=ULTRA_BG, button_color=ULTRA_TEXT, button_hover_color=ULTRA_TEXT_HOVER)
        if hasattr(self, "denoise_slider"):
            self.denoise_slider.configure(progress_color=ULTRA_BG, button_color=ULTRA_TEXT, button_hover_color=ULTRA_TEXT_HOVER)
        self.update_concurrency_buttons_ui()
        if hasattr(self, "status_badge") and "ENCODING" in self.status_badge.cget("text"):
            self.status_badge.configure(text_color=ULTRA_TEXT, fg_color=ULTRA_BG)
        elif hasattr(self, "status_badge") and "PAUSED" in self.status_badge.cget("text"):
            self.status_badge.configure(text_color=HOLD_TEXT, fg_color=HOLD_BG)
        if hasattr(self, "switch_auto_start"):
            self.switch_auto_start.configure(progress_color=ULTRA_BG, button_color=ULTRA_TEXT, button_hover_color=ULTRA_TEXT_HOVER)
        if hasattr(self, "cb_tag_settings"):
            self.cb_tag_settings.configure(fg_color=ULTRA_BG, hover_color=ULTRA_BG_HOVER, border_color=ULTRA_BORDER, checkmark_color=ULTRA_TEXT)
        self.update_action_button_ui()
        self.update_settings_header_label()
        if hasattr(self, "active_jobs_canvas"):
            self.active_jobs_canvas.redraw_all()
        if hasattr(self, "canvas_queue"):
            self.canvas_queue.redraw_all()
        if hasattr(self, "inspector_text"):
            tb = getattr(self.inspector_text, "_textbox", self.inspector_text)
            try:
                tb.tag_configure("sec_h", foreground=ULTRA_TEXT)
            except Exception:
                pass
        if hasattr(self, "_manual_window") and self._manual_window and self._manual_window.winfo_exists():
            for child in self._manual_window.winfo_children():
                if isinstance(child, ctk.CTkTextbox):
                    mtb = getattr(child, "_textbox", child)
                    try:
                        mtb.tag_configure("sec_h", foreground=ULTRA_TEXT)
                        mtb.tag_configure("bullet", foreground=ULTRA_TEXT)
                    except Exception:
                        pass
        if getattr(self, "inspected_data", None) and getattr(self, "inspected_path", None):
            self._render_inspection(self.inspected_data, self.inspected_path)

    def pick_custom_theme_color(self):
        chosen = colorchooser.askcolor(color=ULTRA_TEXT, title="Choose MediaEngine Accent Color")[1]
        if chosen and chosen.startswith("#"):
            self.apply_theme_and_update(chosen, save=True)

    def reset_default_theme_color(self):
        self.apply_theme_and_update(DEFAULT_THEME_COLOR, save=False)
        self.append_log(f"[INFO] Highlight color reset to default ({DEFAULT_THEME_COLOR}).\n")

    def _on_theme_dot_click(self, event=None):
        if event and self.is_option_held(event):
            self.reset_default_theme_color()
        else:
            self.pick_custom_theme_color()

    def _show_theme_dot_menu(self, event):
        try:
            menu = tk.Menu(self.root, tearoff=0)
            menu.add_command(label="Choose Highlight Color...", command=self.pick_custom_theme_color)
            menu.add_command(label=f"Reset to Default ({DEFAULT_THEME_COLOR})", command=self.reset_default_theme_color)
            menu.tk_popup(event.x_root, event.y_root)
        except Exception:
            pass

    def get_settings_summary_str(self):
        try:
            c_raw = self.codec_var.get() if hasattr(self, "codec_var") else "HEVC"
            c_name = "HEVC" if "HEVC" in c_raw else ("H.264" if "H.264" in c_raw else c_raw)
            enc = self.encoder_var.get() if hasattr(self, "encoder_var") else "AppleMediaEngine"
            s_parts = [f"{c_name} (CPU)" if enc == "CPU" else c_name]
            if hasattr(self, "chroma_var") and self.chroma_var.get():
                s_parts.append(self.chroma_var.get())
            if hasattr(self, "quality_slider"):
                q = int(round(float(self.quality_slider.get())))
                crf_disp = max(0, min(51, 51 - q)) if enc == "CPU" else q
                s_parts.append(f"Q{q}" if enc == "AppleMediaEngine" else f"CRF {crf_disp}")
            if hasattr(self, "denoise_slider"):
                try:
                    d_raw = float(self.denoise_slider.get())
                    d_int = int(round(d_raw * 1000)) if 0.0 < d_raw < 1.0 else int(round(d_raw))
                except Exception:
                    d_int = 0
                if d_int > 0:
                    s_parts.append(f"DN {d_int}")
            return " • ".join(s_parts)
        except Exception:
            return ""

    def load_saved_auto_start(self):
        try:
            if os.path.exists(AUTO_START_FILE):
                with open(AUTO_START_FILE, "r", encoding="utf-8") as f:
                    return f.read().strip() == "1"
        except Exception: pass
        return False

    def save_auto_start(self, val):
        try:
            os.makedirs(USER_PRESETS_DIR, exist_ok=True)
            with open(AUTO_START_FILE, "w", encoding="utf-8") as f:
                f.write("1" if val else "0")
        except Exception: pass

    def toggle_auto_start(self):
        val = bool(self.switch_auto_start.get())
        self.auto_start = val
        self.save_auto_start(val)

    def load_saved_tag_settings(self):
        try:
            if os.path.exists(TAG_SETTINGS_FILE):
                with open(TAG_SETTINGS_FILE, "r", encoding="utf-8") as f:
                    return f.read().strip() == "1"
        except Exception: pass
        return False

    def save_tag_settings(self, val):
        try:
            os.makedirs(USER_PRESETS_DIR, exist_ok=True)
            with open(TAG_SETTINGS_FILE, "w", encoding="utf-8") as f:
                f.write("1" if val else "0")
        except Exception: pass

    def toggle_tag_settings(self):
        val = bool(self.cb_tag_settings.get())
        self.tag_settings = val
        self.save_tag_settings(val)
        self.apply_settings_to_selected()

    def update_settings_header_label(self):
        if not hasattr(self, "lbl_settings_toggle"):
            return
        arrow = "▼" if getattr(self, "settings_expanded", True) else "▶"
        sel = getattr(self, "selected_queue_ids", set())
        if not sel:
            self.lbl_settings_toggle.configure(text=f"{arrow}  ENCODING SETTINGS", text_color=TEXT_MUTED)
        elif len(sel) == 1:
            item_id = next(iter(sel))
            with self.queue_lock:
                item = self.items_by_id.get(item_id)
                name = item.get("filename", f"Item #{item_id}") if item else f"Item #{item_id}"
            disp_n = (name[:25] + "...") if len(name) > 28 else name
            self.lbl_settings_toggle.configure(text=f"{arrow}  SETTINGS (Editing: {disp_n})", text_color=ULTRA_TEXT)
        else:
            self.lbl_settings_toggle.configure(text=f"{arrow}  SETTINGS (Editing {len(sel)} Selected)", text_color=ULTRA_TEXT)

    def update_settings_summary(self):
        if hasattr(self, "lbl_settings_summary"):
            sel = getattr(self, "selected_queue_ids", set())
            if sel:
                self.lbl_settings_summary.configure(text="✕ Deselect", text_color=ULTRA_TEXT)
            elif not getattr(self, "settings_expanded", True):
                self.lbl_settings_summary.configure(text=self.get_settings_summary_str(), text_color=TEXT_MUTED)
            else:
                self.lbl_settings_summary.configure(text="", text_color=TEXT_MUTED)

    def _on_settings_summary_click(self):
        if getattr(self, "selected_queue_ids", set()):
            self.clear_selection()
        else:
            self.toggle_settings_panel()

    def toggle_settings_panel(self):
        self.settings_expanded = not self.settings_expanded
        try:
            os.makedirs(USER_PRESETS_DIR, exist_ok=True)
            with open(SETTINGS_STATE_FILE, "w", encoding="utf-8") as f:
                f.write("1" if self.settings_expanded else "0")
        except Exception: pass
        self.update_settings_header_label()
        if self.settings_expanded:
            self.settings_body.pack(fill="x", padx=0, pady=(0, 4))
        else:
            self.settings_body.pack_forget()
        self.update_settings_summary()

    def load_batch_expanded_state(self):
        try:
            if os.path.exists(BATCH_STATE_FILE):
                with open(BATCH_STATE_FILE, "r", encoding="utf-8") as f:
                    return f.read().strip() != "0"
        except Exception: pass
        return True

    def load_saved_batch_height(self):
        default_h = int(3.5 * QuartzActiveJobsCanvas.ROW_STEP) + 4
        try:
            if os.path.exists(BATCH_HEIGHT_FILE):
                with open(BATCH_HEIGHT_FILE, "r", encoding="utf-8") as f:
                    val = int(f.read().strip())
                    if 42 <= val <= 800:
                        return val
        except Exception: pass
        return default_h

    def save_batch_height(self, h):
        try:
            os.makedirs(USER_PRESETS_DIR, exist_ok=True)
            with open(BATCH_HEIGHT_FILE, "w", encoding="utf-8") as f:
                f.write(str(int(h)))
        except Exception: pass

    def toggle_batch_panel(self):
        self.batch_expanded = not self.batch_expanded
        try:
            os.makedirs(USER_PRESETS_DIR, exist_ok=True)
            with open(BATCH_STATE_FILE, "w", encoding="utf-8") as f:
                f.write("1" if self.batch_expanded else "0")
        except Exception: pass
        if self.batch_expanded:
            self.lbl_batch_toggle.configure(text="▼")
            self.batch_progress_bar.pack_configure(pady=(0, 6))
            self.batch_body.pack(fill="x", padx=0, pady=(0, 4))
            self.update_active_jobs_layout()
        else:
            self.lbl_batch_toggle.configure(text="▶")
            self.batch_progress_bar.pack_configure(pady=(0, 10))
            self.batch_body.pack_forget()

    def _on_active_resizer_press(self, event):
        self._resizer_start_y = event.y_root
        self._resizer_start_h = getattr(self, "active_jobs_height", int(3.5 * QuartzActiveJobsCanvas.ROW_STEP) + 4)

    def _on_active_resizer_motion(self, event):
        if not hasattr(self, "_resizer_start_y"):
            return
        delta = event.y_root - self._resizer_start_y
        new_h = max(42, min(600, int(self._resizer_start_h + delta)))
        self.active_jobs_height = new_h
        self.update_active_jobs_layout()

    def _on_active_resizer_release(self, event):
        self.save_batch_height(self.active_jobs_height)

    def get_saved_preset_choice(self):
        try:
            if os.path.exists(LAST_PRESET_FILE):
                with open(LAST_PRESET_FILE, "r", encoding="utf-8") as f:
                    saved = f.read().strip()
                    if saved in self.presets: return saved
        except Exception: pass
        return "Log Footage"

    def save_last_preset_choice(self, preset_name):
        try:
            os.makedirs(USER_PRESETS_DIR, exist_ok=True)
            with open(LAST_PRESET_FILE, "w", encoding="utf-8") as f: f.write(preset_name.strip())
        except Exception: pass

    def load_presets(self):
        self.presets = get_default_presets()
        try:
            if os.path.exists(USER_PRESETS_FILE):
                with open(USER_PRESETS_FILE, "r") as f:
                    user_data = json.load(f)
                    if isinstance(user_data, dict):
                        for k, v in user_data.items():
                            if k not in DEFAULT_PRESETS or k == "Custom": self.presets[k] = v
        except Exception as e: print(f"[WARNING] Could not load presets: {e}")

    def save_presets_to_disk(self):
        try:
            os.makedirs(USER_PRESETS_DIR, exist_ok=True)
            custom_only = {k: v for k, v in self.presets.items() if k not in DEFAULT_PRESETS or k == "Custom"}
            with open(USER_PRESETS_FILE, "w", encoding="utf-8") as f: json.dump(custom_only, f, indent=2)
        except Exception as e: self.append_log(f"[ERROR] Presets write error: {e}\n")

    def kill_own_processes(self):
        with self.process_lock:
            self.cancel_requested = True
            procs = list(self.active_processes.values())
            for proc in procs:
                try:
                    if proc and proc.poll() is None:
                        safe_killpg(proc, signal.SIGCONT, signal.SIGKILL)
                except Exception: pass
            for proc in procs:
                try:
                    if proc:
                        proc.wait(timeout=0.3)
                except Exception: pass
            self.active_processes.clear()
            self.running_ids.clear()
            self.suspended_ids.clear()
            for t in [t for t in getattr(self, "worker_threads", []) if t.is_alive()]:
                try:
                    t.join(timeout=0.5)
                except Exception: pass
            self.worker_threads = []
            for out_f, lk_f in list(getattr(self, "active_output_files", {}).values()):
                if out_f and os.path.exists(out_f):
                    try:
                        os.remove(out_f)
                    except OSError: pass
                release_output_path(lk_f)
            if hasattr(self, "active_output_files"):
                self.active_output_files.clear()
        cleanup_system_ffmpeg(force_all=True)

    def on_close(self):
        if hasattr(self, "preset_var") and self.preset_var.get() == "Custom":
            self.mark_custom_settings()
        with self.process_lock: has_running = bool(self.active_processes)
        if self.is_running and has_running:
            if messagebox.askyesno("Quit MediaEngine", "Encodes are in progress. Stop them and quit?"):
                self.cancel_requested = True
                self.kill_own_processes()
                cleanup_system_ffmpeg()
                self.root.destroy()
        else:
            self.kill_own_processes()
            cleanup_system_ffmpeg()
            self.root.destroy()

    def preflight_check(self):
        global HAS_VT_422, HAS_VT_SPATIAL_AQ, DEFAULT_CHROMA
        cleanup_system_ffmpeg(force_all=False)
        HAS_VT_422 = check_vt_422_support()
        DEFAULT_CHROMA = "10-Bit 4:2:2" if HAS_VT_422 else "10-Bit 4:2:0"
        HAS_VT_SPATIAL_AQ = check_vt_spatial_aq_support()
        if not HAS_VT_422:
            for p in self.presets.values():
                if isinstance(p, dict) and p.get("chroma") == "10-Bit 4:2:2":
                    p["chroma"] = "10-Bit 4:2:0"
            self.sync_encoder_ui()
            self.update_settings_summary()
            self.append_log("[INFO] Hardware 10-Bit 4:2:2 is not supported on this Mac tier. Defaulted to 10-Bit 4:2:0.\n")
        if not HAS_VT_SPATIAL_AQ:
            self.append_log("[INFO] FFmpeg build does not support -spatial_aq. Spatial AQ disabled.\n")
        missing = []
        if not os.path.exists(FFMPEG_BIN) and not shutil.which("ffmpeg"): missing.append("ffmpeg")
        if not os.path.exists(FFPROBE_BIN) and not shutil.which("ffprobe"): missing.append("ffprobe")
        if missing:
            msg = f"Missing static components: {', '.join(missing)}."
            messagebox.showwarning("Encoder Notice", msg)
            self.append_log(f"[WARNING] {msg}\n")
        self.append_log(f"[INFO] Hardware detected: {self.chip_name} ({self.engine_multiplier} video encode engine{'s' if self.engine_multiplier > 1 else ''}).\n")


    def setup_ui(self):
        self.main_container = ctk.CTkFrame(self.root, fg_color="transparent")
        self.main_container.pack(fill="both", expand=True, padx=16, pady=16)

        header_frame = ctk.CTkFrame(self.main_container, fg_color="transparent")
        header_frame.pack(fill="x", pady=(0, 10))

        self.title_lbl = ctk.CTkLabel(
            header_frame, text="MediaEngine",
            font=ctk.CTkFont(family="SF Pro Display", size=18, weight="bold"),
            text_color=TEXT_PRIMARY,
            cursor="hand2"
        )
        self.title_lbl.pack(side="left")
        self.title_lbl.bind("<Button-1>", lambda e: self.open_user_manual())
        self.title_lbl.bind("<Enter>", lambda e: self.title_lbl.configure(text_color=ULTRA_TEXT))
        self.title_lbl.bind("<Leave>", lambda e: self.title_lbl.configure(text_color=TEXT_PRIMARY))


        self.theme_dot = tk.Canvas(header_frame, width=18, height=18, bg=BG_MAIN, bd=0, highlightthickness=0, cursor="hand2")
        self.theme_dot.pack(side="left", padx=(8, 0), pady=(1, 0))
        self.draw_theme_dot()
        self.theme_dot.bind("<Button-1>", self._on_theme_dot_click)
        self.theme_dot.bind("<Button-2>", self._show_theme_dot_menu)
        self.theme_dot.bind("<Button-3>", self._show_theme_dot_menu)
        self.theme_dot.bind("<Control-Button-1>", self._show_theme_dot_menu)
        self.theme_dot.bind("<Double-Button-1>", lambda e: self.reset_default_theme_color())

        self.status_badge = ctk.CTkLabel(
            header_frame, text="● IDLE",
            font=ctk.CTkFont(family="SF Pro Text", size=13, weight="bold"),
            text_color=DONE_GREEN, fg_color=DONE_BG, corner_radius=6, padx=10, pady=3
        )
        self.status_badge.pack(side="right")


        self.switch_auto_start = ctk.CTkSwitch(
            header_frame, text="Auto Start",
            font=ctk.CTkFont(family="SF Pro Text", size=13, weight="bold"),
            text_color=TEXT_PRIMARY,
            fg_color="#222222",
            progress_color=ULTRA_BG,
            button_color=ULTRA_TEXT,
            button_hover_color=ULTRA_TEXT_HOVER,
            command=self.toggle_auto_start,
            width=42, height=20, switch_width=36, switch_height=18
        )
        if getattr(self, "auto_start", False):
            self.switch_auto_start.select()
        else:
            self.switch_auto_start.deselect()
        self.switch_auto_start.pack(side="right", padx=(0, 14))

        # Settings Card (Collapsible Accordion)
        self.settings_card = ctk.CTkFrame(self.main_container, fg_color=CARD_BG, border_width=0, corner_radius=12)
        self.settings_card.pack(fill="x", pady=(0, 8))

        self.settings_header = ctk.CTkFrame(self.settings_card, fg_color="transparent", cursor="hand2")
        self.settings_header.pack(fill="x", padx=14, pady=(8, 8))
        self.settings_header.bind("<Button-1>", lambda e: self.toggle_settings_panel())

        arrow_init = "▼  ENCODING SETTINGS" if self.settings_expanded else "▶  ENCODING SETTINGS"
        self.lbl_settings_toggle = ctk.CTkLabel(
            self.settings_header, text=arrow_init,
            font=ctk.CTkFont(family="SF Pro Text", size=13, weight="bold"), text_color=TEXT_MUTED, cursor="hand2",
            pady=4
        )
        self.lbl_settings_toggle.pack(side="left")
        self.lbl_settings_toggle.bind("<Button-1>", lambda e: self.toggle_settings_panel())

        self.lbl_settings_summary = ctk.CTkLabel(
            self.settings_header, text="",
            font=ctk.CTkFont(family="SF Pro Text", size=13, weight="bold"), text_color=TEXT_MUTED, cursor="hand2",
            pady=4
        )
        self.lbl_settings_summary.pack(side="right")
        self.lbl_settings_summary.bind("<Button-1>", lambda e: self._on_settings_summary_click())

        self.settings_body = ctk.CTkFrame(self.settings_card, fg_color="transparent")
        if self.settings_expanded:
            self.settings_body.pack(fill="x", padx=0, pady=(0, 4))

        # Row 1: Presets
        r1 = ctk.CTkFrame(self.settings_body, fg_color="transparent")
        r1.pack(fill="x", padx=14, pady=3)
        ctk.CTkLabel(r1, text="Preset", width=65, anchor="w", font=ctk.CTkFont(family="SF Pro Text", size=13, weight="bold")).pack(side="left")

        self.preset_var = ctk.StringVar(value="Log Footage")
        self.preset_cb = ctk.CTkOptionMenu(
            r1, values=list(self.presets.keys()), variable=self.preset_var, command=self.on_preset_change,
            fg_color="#1a1a1a", button_color="#242424", button_hover_color="#2e2e2e", corner_radius=8, height=30,
            font=ctk.CTkFont(family="SF Pro Text", size=13, weight="bold"), dropdown_font=ctk.CTkFont(family="SF Pro Text", size=13, weight="bold")
        )
        self.preset_cb.pack(side="left", fill="x", expand=True, padx=(0, 6))

        self.btn_save_preset = ctk.CTkButton(
            r1, text="Save", width=60, height=30, corner_radius=8, fg_color=NEUTRAL_BTN, hover_color=NEUTRAL_BTN_HOVER,
            font=ctk.CTkFont(family="SF Pro Text", size=13, weight="bold"), command=self.save_current_as_preset
        )
        self.btn_save_preset.pack(side="left", padx=(0, 4))

        self.btn_del_preset = ctk.CTkButton(
            r1, text="Delete", width=65, height=30, corner_radius=8, fg_color=NEUTRAL_BTN, hover_color=NEUTRAL_BTN_HOVER,
            font=ctk.CTkFont(family="SF Pro Text", size=13, weight="bold"), command=self.delete_selected_preset
        )
        self.btn_del_preset.pack(side="left")

        # Row 2: Codec, Encoder, Format
        r2 = ctk.CTkFrame(self.settings_body, fg_color="transparent")
        r2.pack(fill="x", padx=14, pady=3)

        ctk.CTkLabel(r2, text="Codec", width=65, anchor="w", font=ctk.CTkFont(family="SF Pro Text", size=13, weight="bold")).pack(side="left")
        self.codec_var = ctk.StringVar(value="HEVC (H.265)")
        self.codec_cb = ctk.CTkOptionMenu(r2, values=["HEVC (H.265)", "H.264"], variable=self.codec_var, command=self.on_codec_menu_change, width=135, height=30, corner_radius=8, fg_color="#1a1a1a", button_color="#242424", button_hover_color="#2e2e2e", font=ctk.CTkFont(family="SF Pro Text", size=13, weight="bold"), dropdown_font=ctk.CTkFont(family="SF Pro Text", size=13, weight="bold"))
        self.codec_cb.pack(side="left", padx=(0, 10))

        ctk.CTkLabel(r2, text="Engine", width=46, anchor="w", font=ctk.CTkFont(family="SF Pro Text", size=13, weight="bold")).pack(side="left")
        self.encoder_var = ctk.StringVar(value="AppleMediaEngine")
        self.encoder_cb = ctk.CTkOptionMenu(r2, values=["AppleMediaEngine", "CPU"], variable=self.encoder_var, command=self.on_encoder_menu_change, width=155, height=30, corner_radius=8, fg_color="#1a1a1a", button_color="#242424", button_hover_color="#2e2e2e", font=ctk.CTkFont(family="SF Pro Text", size=13, weight="bold"), dropdown_font=ctk.CTkFont(family="SF Pro Text", size=13, weight="bold"))
        self.encoder_cb.pack(side="left", padx=(0, 10))

        ctk.CTkLabel(r2, text="Format", width=46, anchor="w", font=ctk.CTkFont(family="SF Pro Text", size=13, weight="bold")).pack(side="left")
        self.chroma_var = ctk.StringVar(value=DEFAULT_CHROMA)
        chroma_opts = ["10-Bit 4:2:2", "10-Bit 4:2:0", "8-Bit 4:2:0"] if HAS_VT_422 else ["10-Bit 4:2:0", "8-Bit 4:2:0"]
        self.chroma_cb = ctk.CTkOptionMenu(r2, values=chroma_opts, variable=self.chroma_var, command=lambda v: self.mark_custom_settings(), height=30, corner_radius=8, fg_color="#1a1a1a", button_color="#242424", button_hover_color="#2e2e2e", font=ctk.CTkFont(family="SF Pro Text", size=13, weight="bold"), dropdown_font=ctk.CTkFont(family="SF Pro Text", size=13, weight="bold"))
        self.chroma_cb.pack(side="left", fill="x", expand=True)

        # Row 3: Quality
        r_quality = ctk.CTkFrame(self.settings_body, fg_color="transparent")
        r_quality.pack(fill="x", padx=14, pady=3)
        self.lbl_quality_title = ctk.CTkLabel(r_quality, text="Quality", width=65, anchor="w", font=ctk.CTkFont(family="SF Pro Text", size=13, weight="bold"))
        self.lbl_quality_title.pack(side="left")
        self.lbl_quality_val = SplitValueLabel(r_quality, width=255)
        self.lbl_quality_val.configure(text="69 (Sweet Spot - Master)")
        self.lbl_quality_val.pack(side="right")
        self.lbl_quality_val.bind("<Button-1>", lambda e: self.edit_quality_dialog())
        btn_q_minus = ctk.CTkButton(r_quality, text="−", width=22, height=22, corner_radius=6, fg_color="transparent", hover_color=ULTRA_BG, text_color=TEXT_PRIMARY, font=ctk.CTkFont(family="SF Pro Text", size=13, weight="bold"), command=lambda: self.step_quality(-1))
        btn_q_minus.pack(side="left", padx=(0, 4))
        btn_q_plus = ctk.CTkButton(r_quality, text="+", width=22, height=22, corner_radius=6, fg_color="transparent", hover_color=ULTRA_BG, text_color=TEXT_PRIMARY, font=ctk.CTkFont(family="SF Pro Text", size=13, weight="bold"), command=lambda: self.step_quality(1))
        btn_q_plus.pack(side="right", padx=(4, 10))
        self.quality_slider = ctk.CTkSlider(r_quality, from_=1, to=100, number_of_steps=99, command=self.on_quality_slider_change, height=18, fg_color="#222222", progress_color=ULTRA_BG, button_color=ULTRA_TEXT, button_hover_color=ULTRA_TEXT_HOVER)
        self.quality_slider.set(69)
        self.quality_slider.pack(side="left", fill="x", expand=True)
        self.quality_slider.bind("<ButtonRelease-1>", lambda e: self.mark_custom_settings())

        # Row 4: Denoise
        r_denoise = ctk.CTkFrame(self.settings_body, fg_color="transparent")
        r_denoise.pack(fill="x", padx=14, pady=3)
        ctk.CTkLabel(r_denoise, text="Denoise", width=65, anchor="w", font=ctk.CTkFont(family="SF Pro Text", size=13, weight="bold")).pack(side="left")
        self.lbl_denoise_val = SplitValueLabel(r_denoise, width=235)
        self.lbl_denoise_val.configure(text="10 (Subtle • CPU)")
        self.lbl_denoise_val.pack(side="right")
        self.lbl_denoise_val.bind("<Button-1>", lambda e: self.edit_denoise_dialog())
        btn_d_minus = ctk.CTkButton(r_denoise, text="−", width=22, height=22, corner_radius=6, fg_color="transparent", hover_color=ULTRA_BG, text_color=TEXT_PRIMARY, font=ctk.CTkFont(family="SF Pro Text", size=13, weight="bold"), command=lambda: self.step_denoise(-1))
        btn_d_minus.pack(side="left", padx=(0, 4))
        btn_d_plus = ctk.CTkButton(r_denoise, text="+", width=22, height=22, corner_radius=6, fg_color="transparent", hover_color=ULTRA_BG, text_color=TEXT_PRIMARY, font=ctk.CTkFont(family="SF Pro Text", size=13, weight="bold"), command=lambda: self.step_denoise(1))
        btn_d_plus.pack(side="right", padx=(4, 10))
        self.denoise_slider = ctk.CTkSlider(r_denoise, from_=0, to=30, number_of_steps=30, command=self.on_denoise_slider_change, height=18, fg_color="#222222", progress_color=ULTRA_BG, button_color=ULTRA_TEXT, button_hover_color=ULTRA_TEXT_HOVER)
        self.denoise_slider.set(10)
        self.denoise_slider.pack(side="left", fill="x", expand=True)
        self.denoise_slider.bind("<ButtonRelease-1>", lambda e: self.mark_custom_settings())

        for _sl in (self.quality_slider, self.denoise_slider):
            for _w in (_sl, getattr(_sl, "_canvas", None)):
                if _w:
                    for _seq in ("<MouseWheel>", "<TouchpadScroll>", "<Button-4>", "<Button-5>"):
                        try: _w.unbind(_seq)
                        except Exception: pass
                        try: _w.bind(_seq, lambda e: "break")
                        except Exception: pass

        # Row 5: Parallel Buttons (Sequential, Balanced, Turbo)
        r_parallel = ctk.CTkFrame(self.settings_body, fg_color="transparent")
        r_parallel.pack(fill="x", padx=14, pady=3)
        ctk.CTkLabel(r_parallel, text="Parallel", width=65, anchor="w", font=ctk.CTkFont(family="SF Pro Text", size=13, weight="bold")).pack(side="left")

        btn_p_wrap = ctk.CTkFrame(r_parallel, fg_color="transparent")
        btn_p_wrap.pack(side="left", fill="x", expand=True)
        btn_p_wrap.grid_columnconfigure((0, 1, 2), weight=1, uniform="parallel_btn")

        self.btn_parallel_seq = ctk.CTkButton(
            btn_p_wrap, text="Sequential", height=30, corner_radius=8,
            font=ctk.CTkFont(family="SF Pro Text", size=13, weight="bold"),
            command=lambda: self.set_concurrency_mode("Sequential")
        )
        self.btn_parallel_seq.grid(row=0, column=0, sticky="ew", padx=(0, 4))

        self.btn_parallel_bal = ctk.CTkButton(
            btn_p_wrap, text="Balanced", height=30, corner_radius=8,
            font=ctk.CTkFont(family="SF Pro Text", size=13, weight="bold"),
            command=lambda: self.set_concurrency_mode("Balanced")
        )
        self.btn_parallel_bal.grid(row=0, column=1, sticky="ew", padx=(0, 4))

        self.btn_parallel_turbo = ctk.CTkButton(
            btn_p_wrap, text="Turbo", height=30, corner_radius=8,
            font=ctk.CTkFont(family="SF Pro Text", size=13, weight="bold"),
            command=lambda: self.set_concurrency_mode("Turbo")
        )
        self.btn_parallel_turbo.grid(row=0, column=2, sticky="ew", padx=0)
        self.update_concurrency_buttons_ui()

        # Row 6: Output
        r4 = ctk.CTkFrame(self.settings_body, fg_color="transparent")
        r4.pack(fill="x", padx=14, pady=(3, 10))
        ctk.CTkLabel(r4, text="Output", width=65, anchor="w", font=ctk.CTkFont(family="SF Pro Text", size=13, weight="bold")).pack(side="left")
        self.dest_var = ctk.StringVar(value=self.load_saved_output_dir())
        self.dest_var.trace_add("write", self._debounce_dest_change)
        self.cb_tag_settings = ctk.CTkCheckBox(
            r4, text="Append Settings",
            font=ctk.CTkFont(family="SF Pro Text", size=12, weight="bold"),
            text_color=TEXT_PRIMARY,
            fg_color=ULTRA_BG,
            hover_color=ULTRA_BG_HOVER,
            border_color=ULTRA_BORDER,
            checkmark_color=ULTRA_TEXT,
            corner_radius=4,
            width=18, height=18, checkbox_width=18, checkbox_height=18,
            command=self.toggle_tag_settings
        )
        if getattr(self, "tag_settings", False):
            self.cb_tag_settings.select()
        else:
            self.cb_tag_settings.deselect()
        self.cb_tag_settings.pack(side="right")
        browse_btn = ctk.CTkButton(r4, text="Browse", width=66, height=30, corner_radius=8, fg_color=NEUTRAL_BTN, hover_color=NEUTRAL_BTN_HOVER, font=ctk.CTkFont(family="SF Pro Text", size=13, weight="bold"), command=self.browse_dest)
        browse_btn.pack(side="right", padx=(0, 10))
        self.dest_entry = ctk.CTkEntry(r4, textvariable=self.dest_var, height=30, corner_radius=8, fg_color="#1a1a1a", border_width=0, font=ctk.CTkFont(family="SF Pro Text", size=13))
        self.dest_entry.pack(side="left", fill="x", expand=True, padx=(0, 10))
        self.dest_entry.bind("<FocusOut>", self._on_dest_changed, add="+")
        self.dest_entry.bind("<Return>", self._on_dest_changed, add="+")
        self.dest_entry.bind("<KP_Enter>", self._on_dest_changed, add="+")

        # Status Card (Collapsible Batch Accordion)
        self.status_card = ctk.CTkFrame(self.main_container, fg_color=CARD_BG, border_width=0, corner_radius=12)
        self.status_card.pack(fill="x", pady=(0, 10))

        self.batch_header = ctk.CTkFrame(self.status_card, fg_color="transparent", cursor="hand2")
        self.batch_header.pack(fill="x", padx=14, pady=(8, 6))
        self.batch_header.bind("<Button-1>", lambda e: self.toggle_batch_panel())

        batch_arrow_init = "▼" if self.batch_expanded else "▶"
        self.lbl_batch_toggle = ctk.CTkLabel(
            self.batch_header, text=batch_arrow_init,
            font=ctk.CTkFont(family="SF Pro Text", size=13, weight="bold"), text_color=TEXT_MUTED, cursor="hand2"
        )
        self.lbl_batch_toggle.pack(side="left", padx=(0, 6))
        self.lbl_batch_toggle.bind("<Button-1>", lambda e: self.toggle_batch_panel())

        self.lbl_batch_status = ctk.CTkLabel(
            self.batch_header, text="Queue is empty",
            font=ctk.CTkFont(family="SF Pro Text", size=13, weight="bold"), text_color=TEXT_MUTED, cursor="hand2"
        )
        self.lbl_batch_status.pack(side="left")
        self.lbl_batch_status.bind("<Button-1>", lambda e: self.toggle_batch_panel())

        self.lbl_batch_pct = ctk.CTkLabel(
            self.batch_header, text="0%",
            font=ctk.CTkFont(family="SF Pro Text", size=13, weight="bold"), text_color=TEXT_MUTED, cursor="hand2"
        )
        self.lbl_batch_pct.pack(side="right")
        self.lbl_batch_pct.bind("<Button-1>", lambda e: self.toggle_batch_panel())

        self.batch_progress_bar = ctk.CTkProgressBar(self.status_card, height=6, corner_radius=3, fg_color="#222222", progress_color=ULTRA_TEXT)
        self.batch_progress_bar.set(0)
        self.batch_progress_bar.pack(fill="x", padx=14, pady=(0, 6 if self.batch_expanded else 10))

        self.batch_body = ctk.CTkFrame(self.status_card, fg_color="transparent")
        if self.batch_expanded:
            self.batch_body.pack(fill="x", padx=0, pady=(0, 4))

        self.active_jobs_wrap = ctk.CTkFrame(self.batch_body, fg_color="transparent")
        self.active_jobs_wrap.pack(fill="x", padx=10, pady=(0, 10))

        self.active_jobs_inner = ctk.CTkFrame(self.active_jobs_wrap, fg_color="transparent")
        self.active_jobs_inner.pack(fill="x", expand=True)

        self.active_jobs_scrollbar = ctk.CTkScrollbar(self.active_jobs_inner, command=self._on_active_scrollbar_drag, fg_color="transparent", button_color="#262626", button_hover_color="#333333", width=10, height=self.active_jobs_height)
        self.active_jobs_canvas = QuartzActiveJobsCanvas(self.active_jobs_inner, height=self.active_jobs_height, on_layout_needed=self.update_active_jobs_layout)
        self.active_jobs_canvas.pack(side="left", fill="both", expand=True, padx=(0, 2), pady=0)
        self.active_jobs_canvas.configure(yscrollcommand=self._on_active_jobs_scroll_update)

        self.active_jobs_resizer = ctk.CTkFrame(self.active_jobs_wrap, height=10, fg_color="transparent", cursor="sb_v_double_arrow")
        self.active_jobs_resizer.pack(fill="x", pady=(3, 0))

        self.active_jobs_resizer_grip = ctk.CTkFrame(self.active_jobs_resizer, width=38, height=3, corner_radius=2, fg_color="#262626", cursor="sb_v_double_arrow")
        self.active_jobs_resizer_grip.place(relx=0.5, rely=0.5, anchor="center")

        for w in (self.active_jobs_resizer, self.active_jobs_resizer_grip):
            w.bind("<ButtonPress-1>", self._on_active_resizer_press)
            w.bind("<B1-Motion>", self._on_active_resizer_motion)
            w.bind("<ButtonRelease-1>", self._on_active_resizer_release)
            w.bind("<Enter>", lambda e: self.active_jobs_resizer_grip.configure(fg_color="#383838"))
            w.bind("<Leave>", lambda e: self.active_jobs_resizer_grip.configure(fg_color="#262626"))

        self.update_active_jobs_layout()

        # Action Buttons
        btn_frame = ctk.CTkFrame(self.main_container, fg_color="transparent")
        btn_frame.pack(fill="x", pady=(0, 10))

        self.btn_pause = ctk.CTkButton(btn_frame, text="▶  Start", width=96, height=30, corner_radius=8, font=ctk.CTkFont(family="SF Pro Text", size=13, weight="bold"), command=self.handle_action_button)
        self.btn_pause.pack(side="left", padx=(0, 6))

        self.btn_cancel = ctk.CTkButton(btn_frame, text="⏹  Kill & Skip", width=108, height=30, corner_radius=8, fg_color=NEUTRAL_BTN, hover_color=NEUTRAL_BTN_HOVER, font=ctk.CTkFont(family="SF Pro Text", size=13, weight="bold"), command=self.cancel_current, state="disabled")
        self.btn_cancel.pack(side="left", padx=(0, 6))

        self.btn_clear_done = ctk.CTkButton(btn_frame, text="Clear Finished", width=115, height=30, corner_radius=8, fg_color=NEUTRAL_BTN, hover_color=NEUTRAL_BTN_HOVER, font=ctk.CTkFont(family="SF Pro Text", size=13, weight="bold"), command=self.clear_completed_items)
        self.btn_clear_done.pack(side="left", padx=(0, 6))

        self.btn_clear_queue = ctk.CTkButton(btn_frame, text="Clear Queued", width=110, height=30, corner_radius=8, fg_color=NEUTRAL_BTN, hover_color=NEUTRAL_BTN_HOVER, font=ctk.CTkFont(family="SF Pro Text", size=13, weight="bold"), command=self.clear_queued_items)
        self.btn_clear_queue.pack(side="left")

        self.btn_add_files = ctk.CTkButton(
            btn_frame, text="＋  Files", width=86, height=30, corner_radius=8,
            fg_color=NEUTRAL_BTN, hover_color=NEUTRAL_BTN_HOVER,
            font=ctk.CTkFont(family="SF Pro Text", size=13, weight="bold"),
            command=self.add_files_dialog
        )
        self.btn_add_files.pack(side="right")

        self.btn_add_folder = ctk.CTkButton(
            btn_frame, text="＋  Folder", width=92, height=30, corner_radius=8,
            fg_color=NEUTRAL_BTN, hover_color=NEUTRAL_BTN_HOVER,
            font=ctk.CTkFont(family="SF Pro Text", size=13, weight="bold"),
            command=self.add_folder_dialog
        )
        self.btn_add_folder.pack(side="right", padx=(0, 6))

        # Main Segmented Tab View
        self.tabview = ctk.CTkTabview(
            self.main_container,
            anchor="nw",
            command=self._on_tab_changed,
            fg_color=CARD_BG,
            border_width=0,
            segmented_button_fg_color="#0e0e0e",
            segmented_button_selected_color="#222222",
            segmented_button_selected_hover_color="#2c2c2c",
            segmented_button_unselected_color="#141414",
            segmented_button_unselected_hover_color="#1a1a1a"
        )
        seg_btn = getattr(self.tabview, "_segmented_button", None)
        if seg_btn:
            seg_btn.configure(font=ctk.CTkFont(family="SF Pro Text", size=13, weight="bold"), height=40, corner_radius=8)
        self.tabview.pack(fill="both", expand=True)

        self.tab_queue = self.tabview.add("Batch Queue")
        self.tab_inspector = self.tabview.add("Media Inspector")
        self.tab_logs = self.tabview.add("Live Console")
        self.tabview.set("Batch Queue")

        # Tab 1: Queue
        queue_wrap = ctk.CTkFrame(self.tab_queue, fg_color="transparent")
        queue_wrap.pack(fill="both", expand=True, padx=4, pady=4)

        self.canvas_queue = QuartzQueueCanvas(
            queue_wrap,
            on_remove_item=self.remove_or_cancel_item,
            on_inspect_item=self.inspect_queued_item,
            on_select_item=self.on_queue_item_selected
        )
        self.canvas_queue.pack(side="left", fill="both", expand=True, padx=(0, 4), pady=2)
        self.queue_scrollbar = ctk.CTkScrollbar(queue_wrap, command=self._on_queue_scrollbar_drag, fg_color="transparent", button_color="#262626", button_hover_color="#333333")
        self.queue_scrollbar.pack(side="right", fill="y", pady=2)
        self.canvas_queue.configure(yscrollcommand=self.queue_scrollbar.set)

        # Tab 2: Media Inspector UI
        self.setup_inspector_tab()

        # Tab 3: Console
        self.log_text = ctk.CTkTextbox(self.tab_logs, font=ctk.CTkFont(family="SF Mono", size=10), fg_color="#0e0e0e", text_color="#d8d8d8", corner_radius=8, border_width=1, border_color="#1e1e1e")
        self.log_text.pack(fill="both", expand=True, padx=4, pady=4)

        def get_log_metrics():
            tb = getattr(self.log_text, "_textbox", None)
            if not tb or not tb.winfo_ismapped(): return None
            view_h = float(tb.winfo_height())
            if view_h <= 0: return None
            top_frac, bot_frac = tb.yview()
            vis_frac = max(0.0001, bot_frac - top_frac)
            return (view_h, view_h, 0.0) if vis_frac >= 0.9999 else (view_h, view_h / vis_frac, top_frac)

        self.log_scroller = QuartzKineticScroller(
            get_view_metrics=get_log_metrics,
            set_view_fraction=lambda f: getattr(self.log_text, "_textbox").yview_moveto(f) if getattr(self.log_text, "_textbox", None) else None,
            after_fn=self.log_text.after,
            cancel_after_fn=self.log_text.after_cancel
        )

        self.scroll_handler = UniversalScrollHandler(
            self.root,
            queue_scroller=self.canvas_queue.scroller,
            active_jobs_scroller=self.active_jobs_canvas.scroller,
            log_scroller=self.log_scroller,
            inspector_scroller=self.inspector_scroller,
            queue_canvas=self.canvas_queue,
            active_jobs_canvas=self.active_jobs_canvas,
            log_textbox=self.log_text,
            inspector_view=self.inspector_text
        )
        self.update_action_button_ui()

    def open_user_manual(self):
        if hasattr(self, "_manual_window") and self._manual_window and self._manual_window.winfo_exists():
            self._manual_window.lift()
            self._manual_window.focus_force()
            return

        # Center the manual directly over the main window
        self.root.update_idletasks()
        rx, ry = self.root.winfo_rootx(), self.root.winfo_rooty()
        rw, rh = self.root.winfo_width(), self.root.winfo_height()
        w_manual = min(740, max(640, rw))
        h_manual = min(860, max(600, rh))
        pos_x = max(0, rx + (rw - w_manual) // 2)
        pos_y = max(0, ry + (rh - h_manual) // 2)

        win = ctk.CTkToplevel(self.root)
        win.withdraw()
        self._manual_window = win
        win.title("MediaEngine - User Manual & Guide")
        win.geometry(f"{w_manual}x{h_manual}+{pos_x}+{pos_y}")
        win.minsize(640, 560)
        win.configure(fg_color=BG_MAIN)

        top_bar = ctk.CTkFrame(win, fg_color="transparent")
        top_bar.pack(fill="x", padx=16, pady=(12, 8))

        lbl_top = ctk.CTkLabel(
            top_bar, text="MediaEngine User Manual",
            font=ctk.CTkFont(family="SF Pro Display", size=17, weight="bold"),
            text_color=TEXT_PRIMARY
        )
        lbl_top.pack(side="left")

        btn_kofi = ctk.CTkButton(
            top_bar, text="☕ Support on Ko-fi", width=145, height=30, corner_radius=8,
            fg_color=NEUTRAL_BTN, hover_color=NEUTRAL_BTN_HOVER, text_color=TEXT_PRIMARY,
            font=ctk.CTkFont(family="SF Pro Text", size=12, weight="bold"),
            command=lambda: webbrowser.open("https://ko-fi.com/jondana")
        )
        btn_kofi.pack(side="right")

        manual_text = ctk.CTkTextbox(
            win,
            font=ctk.CTkFont(family="SF Pro Text", size=13),
            fg_color="#0e0e0e",
            text_color="#e0e0e0",
            corner_radius=8,
            border_width=1,
            border_color="#1e1e1e",
            wrap="word"
        )
        manual_text.pack(fill="both", expand=True, padx=16, pady=(0, 10))

        def get_manual_metrics():
            tb_inner = getattr(manual_text, "_textbox", None)
            if not tb_inner or not tb_inner.winfo_ismapped(): return None
            view_h = float(tb_inner.winfo_height())
            if view_h <= 0: return None
            top_frac, bot_frac = tb_inner.yview()
            vis_frac = max(0.0001, bot_frac - top_frac)
            return (view_h, view_h, 0.0) if vis_frac >= 0.9999 else (view_h, view_h / vis_frac, top_frac)

        manual_scroller = QuartzKineticScroller(
            get_view_metrics=get_manual_metrics,
            set_view_fraction=lambda f: getattr(manual_text, "_textbox").yview_moveto(f) if getattr(manual_text, "_textbox", None) else None,
            after_fn=manual_text.after,
            cancel_after_fn=manual_text.after_cancel
        )

        if hasattr(self, "scroll_handler"):
            self.scroll_handler.manual_scroller = manual_scroller
            self.scroll_handler.manual_view = manual_text

        def _on_manual_wheel(event):
            try:
                raw_delta = getattr(event, "delta", 0)
                if getattr(event, "num", None) == 4: raw_delta = 1
                elif getattr(event, "num", None) == 5: raw_delta = -1
                if raw_delta != 0:
                    manual_scroller.handle_wheel_input(float(raw_delta))
                    return "break"
            except Exception:
                pass

        for seq in ("<MouseWheel>", "<TouchpadScroll>", "<Button-4>", "<Button-5>"):
            try:
                win.bind(seq, _on_manual_wheel, add="+")
                manual_text.bind(seq, _on_manual_wheel, add="+")
                if hasattr(manual_text, "_textbox"):
                    manual_text._textbox.bind(seq, _on_manual_wheel, add="+")
            except Exception:
                pass

        tb = getattr(manual_text, "_textbox", manual_text)
        tb.configure(state="normal", padx=20, pady=16)
        tb.delete("1.0", "end")

        tb.tag_configure("sec_h", font=("SF Pro Display", 14, "bold"), foreground=ULTRA_TEXT, spacing1=22, spacing3=6)
        tb.tag_configure("sec_h_top", font=("SF Pro Display", 14, "bold"), foreground=ULTRA_TEXT, spacing1=2, spacing3=6)
        tb.tag_configure("intro", font=("SF Pro Text", 12), foreground="#9aa4a9", spacing1=2, spacing2=4, spacing3=10, lmargin1=4, lmargin2=4)
        tb.tag_configure("item", lmargin1=10, lmargin2=30, tabs=(30,), spacing1=3, spacing2=3, spacing3=5)
        tb.tag_configure("bullet", font=("SF Pro Text", 12, "bold"), foreground=ULTRA_TEXT)
        tb.tag_configure("val", font=("SF Pro Text", 12, "bold"), foreground=TEXT_PRIMARY)
        tb.tag_configure("body", font=("SF Pro Text", 12), foreground="#c4cbcf")

        sections = [
            ("1. OVERVIEW & ARCHITECTURE",
             "MediaEngine is engineered specifically for demanding production and cinema workflows (such as 8K Canon Cinema RAW Light & C-Log3), compressing massive takes down to 30–40 Mbps while preserving full 10-bit color accuracy and grading headroom.",
             [
                 ("Native Apple Silicon", "Optimized directly for macOS hardware media encode and decode engines."),
                 ("Zero Ingest Stalls", "Drag in hundreds of clips instantly without preliminary preview stalls or caching delays."),
                 ("Hardware Constant Quality", "Operates via VideoToolbox -q:v for visual fidelity without arbitrary bitrate limits."),
                 ("Edit-Ready Masters", "Produces compliant hvc1/avc1 bitstreams with instant playback in DaVinci Resolve and FCP."),
                 ("Color Science Integrity", "Strictly preserves NCLX color atoms, HDR mastering display (ST 2086), and light levels.")
             ]),

            ("2. SILICON HARDWARE TIERS & CONCURRENCY",
             "Encode streams are dynamically budgeted: 8K streams consume 6 resource units (strictly 1 per engine), 4K streams take 2 units, and HD/1440p take 1 unit to prevent GPU lock contention.",
             [
                 ("Base / Pro (M1–M4)", "1 Dedicated Hardware Video Encode Engine."),
                 ("Max Chips", "2 Dedicated Hardware Video Encode Engines."),
                 ("Ultra Chips", "4 Dedicated Hardware Video Encode Engines."),
                 ("Sequential Mode", "Strictly 1 job at a time. Ideal for massive 8K masters or heavy background multitasking."),
                 ("Balanced Mode", "Recommended daily driver. Saturates silicon (2 jobs per engine) via weighted budgeting."),
                 ("Turbo Mode", "Maximum throughput saturation protected by active RAM and memory pressure guardrails.")
             ]),

            ("3. RECOMMENDED PRESETS & BEST SETTINGS",
             "If your Mac tier lacks hardware 10-Bit 4:2:2 encode support, MediaEngine safely falls back to 10-Bit 4:2:0 without crashing or dropping bit depth.",
             [
                 ("Log Footage Preset", "HEVC • 10-Bit 4:2:2 • Quality: 69 • Denoise: 10"),
                 ("Why Q69 for Log?", "Preserves shadow latitude, fine grain structure, and subtle gradations without banding."),
                 ("Non-Log Preset", "HEVC • 10-Bit 4:2:0 • Quality: 58 • Denoise: 15"),
                 ("Why Q58 for Rec.709?", "Optimal sweet spot for delivery, web, and archives with high compression and zero visible loss."),
                 ("Software (CPU) Mode", "libx265 / libx264 with tuned psycho-visual RD, SAO disabled, and AQ mode 3 for deep control.")
             ]),

            ("4. PERCEPTUAL NOISE REDUCTION (ATADENOISE)",
             "Denoise Settings Guide: 0 = Off (fastest), 5–10 = Subtle (clean cinema log), 15–22 = Moderate (high-ISO grain).",
             [
                 ("Chroma-Biased Filter", "Human vision notices luma edges far more than chroma noise; chroma grain is heavily attenuated."),
                 ("Bitrate Conservation", "Strips high-frequency sensor noise from dark shadows, saving bitrate for visible detail."),
                 ("Dynamic Temporal Window", "Averages across 5 to 9 successive frames depending on strength, avoiding motion ghosting."),
                 ("HDR Safety Bypass", "Temporal denoising is automatically bypassed on HDR (PQ/HLG) to prevent highlight stepping.")
             ]),

            ("5. TRANSPARENCY & ALPHA PRESERVATION",
             "Hardware-accelerated ProRes 4444 and animation alpha channel transcoding with zero quality degradation.",
             [
                 ("Automatic Alpha Routing", "Detects ProRes 4444, Animation, and PNG sequences with embedded alpha channels."),
                 ("Hardware Alpha Pipeline", "Premultiplies alpha and routes through 32-bit BGRA VideoToolbox to generate .mov masters."),
                 ("Ultra-Compact Masters", "Generates transparent HEVC files up to 90% smaller than ProRes 4444.")
             ]),

            ("6. MEDIA INSPECTOR & SHORTCUTS",
             "Deep stream inspection, NCLX color atom verification, and production productivity shortcuts.",
             [
                 ("Option-Drop (⌥)", "Hold Option while dropping any file or folder to open directly in the Media Inspector."),
                 ("Deep Media Inspector", "Inspects video/audio streams, NCLX atoms, HDR side data, channel layouts, or raw JSON."),
                 ("Add to Queue", "One-click button in the Inspector to immediately queue an inspected video."),
                 ("Per-Item Settings", "Click any queued item to customize its preset, codec, or quality independently."),
                 ("Multi-Select", "Shift-click to select a range; Cmd-click to toggle multiple queued clips."),
                 ("Delete / Backspace", "Removes selected queued items from the batch list."),
                 ("Accent Color Dot", "Click the split-color dot in the header to change theme. Double-click or Option-click to reset.")
             ]),

            ("7. SUPPORT & CONTRIBUTIONS",
             "MediaEngine is free and open source under the GNU General Public License v3.0 (GPL-3.0).",
             [
                 ("Ko-fi Page", "https://ko-fi.com/jondana"),
                 ("Author", "Jon Dana (https://github.com/jondana/MediaEngine)"),
                 ("Contributions", "If this tool saves you time, cuts render hours, or frees up disk space, support on Ko-fi is warmly appreciated!")
             ])
        ]

        for sec_idx, (sec_title, intro, items) in enumerate(sections):
            h_tags = ("sec_h", "sec_h_top") if sec_idx == 0 else "sec_h"
            tb.insert("end", f"{sec_title}\n", h_tags)
            if intro:
                tb.insert("end", f"{intro}\n", "intro")
            for lbl, val in items:
                sep = "" if lbl.endswith("?") else ":"
                tb.insert("end", "•\t", ("bullet", "item"))
                tb.insert("end", f"{lbl}{sep} ", ("val", "item"))
                tb.insert("end", f"{val}\n", ("body", "item"))

        tb.configure(state="disabled")
        win.after(60, manual_scroller.sync_position)

        bottom_bar = ctk.CTkFrame(win, fg_color="transparent")
        bottom_bar.pack(fill="x", padx=16, pady=(6, 12))

        btn_close = ctk.CTkButton(
            bottom_bar, text="Close", width=90, height=32, corner_radius=8,
            fg_color=NEUTRAL_BTN, hover_color=NEUTRAL_BTN_HOVER, text_color=TEXT_PRIMARY,
            font=ctk.CTkFont(family="SF Pro Text", size=12, weight="bold"),
            command=win.destroy
        )
        btn_close.pack(side="right")

        win.deiconify()
        win.lift()
        win.focus_force()
    # ----------------------------------------------------
    # MEDIA INSPECTOR UI & PARSER
    # ----------------------------------------------------
    def setup_inspector_tab(self):
        top_bar = ctk.CTkFrame(self.tab_inspector, fg_color="transparent")
        top_bar.pack(fill="x", padx=6, pady=(4, 6))

        self.btn_inspect_browse = ctk.CTkButton(
            top_bar, text="Choose File...", width=120, height=30, corner_radius=8,
            fg_color=NEUTRAL_BTN, hover_color=NEUTRAL_BTN_HOVER,
            font=ctk.CTkFont(family="SF Pro Text", size=13, weight="bold"),
            command=self.browse_inspect_file
        )
        self.btn_inspect_browse.pack(side="left", padx=(0, 6))

        self.btn_inspect_to_queue = ctk.CTkButton(
            top_bar, text="➕ Add to Queue", width=135, height=30, corner_radius=8,
            fg_color=NEUTRAL_BTN, hover_color=NEUTRAL_BTN_HOVER,
            font=ctk.CTkFont(family="SF Pro Text", size=13, weight="bold"),
            command=self.send_inspected_to_queue,
            state="disabled"
        )
        self.btn_inspect_to_queue.pack(side="left")

        self.btn_inspect_copy = ctk.CTkButton(
            top_bar, text="Copy Summary", width=130, height=30, corner_radius=8,
            fg_color=NEUTRAL_BTN, hover_color=NEUTRAL_BTN_HOVER,
            font=ctk.CTkFont(family="SF Pro Text", size=13, weight="bold"),
            command=self.copy_inspector_summary
        )
        self.btn_inspect_copy.pack(side="right")
        # Quick Specs Badges Bar
        self.badges_bar = ctk.CTkFrame(self.tab_inspector, fg_color="transparent")
        self.badges_bar.pack(fill="x", padx=6, pady=(0, 6))
        self.badges_bar.pack_propagate(False)
        self.badges_bar.bind("<Configure>", lambda e: self._reflow_badges())
        self._badge_widgets = []

        # Main Scrollable Display for Inspector with SF Mono typography
        self.inspector_text = ctk.CTkTextbox(
            self.tab_inspector,
            font=ctk.CTkFont(family="SF Pro Text", size=12),
            fg_color="#0e0e0e",
            text_color="#e0e0e0",
            corner_radius=8,
            border_width=1,
            border_color="#1e1e1e",
            wrap="none"
        )
        self.inspector_text.pack(fill="both", expand=True, padx=6, pady=(0, 6))

        # Kinetic scroller for inspector view
        def get_inspector_metrics():
            tb = getattr(self.inspector_text, "_textbox", None)
            if not tb or not tb.winfo_ismapped(): return None
            view_h = float(tb.winfo_height())
            if view_h <= 0: return None
            top_frac, bot_frac = tb.yview()
            vis_frac = max(0.0001, bot_frac - top_frac)
            return (view_h, view_h, 0.0) if vis_frac >= 0.9999 else (view_h, view_h / vis_frac, top_frac)

        self.inspector_scroller = QuartzKineticScroller(
            get_view_metrics=get_inspector_metrics,
            set_view_fraction=lambda f: getattr(self.inspector_text, "_textbox").yview_moveto(f) if getattr(self.inspector_text, "_textbox", None) else None,
            after_fn=self.inspector_text.after,
            cancel_after_fn=self.inspector_text.after_cancel
        )

        tb = getattr(self.inspector_text, "_textbox", self.inspector_text)
        tb.bind("<Configure>", lambda e: self._on_inspector_resize(e), add="+")
        self.show_inspector_placeholder()

    def clear_badges(self):
        if hasattr(self, "badges_bar"):
            for w in self.badges_bar.winfo_children():
                w.destroy()
            self._badge_widgets = []
            self._last_badges_w = None
            self.badges_bar.configure(height=0)

    def _reflow_badges(self, event=None, force=False):
        if not getattr(self, "_badge_widgets", None):
            return

        avail_w = 0
        if event and getattr(event, "width", 0) > 50:
            avail_w = event.width
        if avail_w <= 50 and hasattr(self, "badges_bar"):
            avail_w = self.badges_bar.winfo_width()
        if avail_w <= 50 and hasattr(self, "tab_inspector"):
            df_w = self.tab_inspector.winfo_width()
            if df_w > 50:
                avail_w = df_w - 24
        if avail_w <= 50:
            rw = self.root.winfo_width()
            avail_w = (rw - 50) if rw > 50 else 700

        if not force and getattr(self, "_last_badges_w", None) == avail_w:
            return
        self._last_badges_w = avail_w

        badges = self._badge_widgets
        n = len(badges)
        if n == 0:
            return

        gap_x = 6
        gap_y = 6
        row_h = 30

        def get_min_w(b):
            if hasattr(b, "_min_w"):
                return b._min_w
            txt = getattr(b, "_text", "")
            return max(85, len(str(txt)) * 8 + 20)

        min_w_map = {b: get_min_w(b) for b in badges}

        best_rows = None
        for r in range(1, n + 1):
            base_cnt = n // r
            rem = n % r
            cand_rows = []
            cur_idx = 0
            for i in range(r):
                c = base_cnt + (1 if i < rem else 0)
                cand_rows.append(badges[cur_idx:cur_idx + c])
                cur_idx += c

            fits = True
            for row in cand_rows:
                k = len(row)
                if k == 0:
                    continue
                row_min = sum(min_w_map[x] for x in row) + (k - 1) * gap_x
                if row_min > avail_w:
                    fits = False
                    break

            if fits:
                best_rows = cand_rows
                break

        if not best_rows:
            best_rows = []
            cur_row = []
            cur_row_w = 0
            for b in badges:
                bw = min_w_map[b]
                needed = bw if not cur_row else bw + gap_x
                if cur_row and (cur_row_w + needed > avail_w):
                    best_rows.append(cur_row)
                    cur_row = [b]
                    cur_row_w = bw
                else:
                    cur_row.append(b)
                    cur_row_w += needed
            if cur_row:
                best_rows.append(cur_row)

        cur_y = 0
        for row in best_rows:
            k = len(row)
            if k == 0:
                continue

            row_min_sum = sum(min_w_map[b] for b in row)
            total_gaps = (k - 1) * gap_x
            avail_cards_w = max(0, avail_w - total_gaps)
            extra_w = max(0, avail_cards_w - row_min_sum)

            cur_x = 0
            for j, b in enumerate(row):
                min_w = min_w_map[b]
                if k == 1:
                    w_px = min(max(min_w, 180), avail_w)
                else:
                    add_w = (extra_w * (min_w / row_min_sum)) if row_min_sum > 0 else (extra_w / k)
                    w_px = max(min_w, round(min_w + add_w))

                if j == k - 1 and k > 1 and extra_w > 0:
                    w_px = max(min_w, avail_w - cur_x)

                b.configure(width=int(w_px), height=int(row_h))
                b.place(x=int(cur_x), y=int(cur_y))
                cur_x += int(w_px) + gap_x

            cur_y += row_h + gap_y

        total_h = max(row_h, cur_y - gap_y)
        self.badges_bar.configure(height=total_h)

    def add_stat_card(self, title, value, bg_col, text_col, border_col="#242424", reflow=True):
        card = ctk.CTkFrame(
            self.badges_bar,
            fg_color=bg_col,
            corner_radius=7,
            border_width=1,
            border_color=border_col
        )
        card.pack_propagate(False)

        # Data value placed to the LEFT of the title word
        lbl_v = ctk.CTkLabel(
            card,
            text=str(value),
            font=ctk.CTkFont(family="SF Pro Text", size=12, weight="bold"),
            text_color="#f5f5f7",
            anchor="w"
        )
        lbl_v.pack(side="left", padx=(10, 6))

        lbl_t = ctk.CTkLabel(
            card,
            text=str(title).upper(),
            font=ctk.CTkFont(family="SF Pro Text", size=9, weight="bold"),
            text_color=text_col,
            anchor="w"
        )
        lbl_t.pack(side="left", padx=(0, 10))

        card._min_w = max(100, (len(str(value)) + len(str(title))) * 7 + 28)
        if not hasattr(self, "_badge_widgets"):
            self._badge_widgets = []
        self._badge_widgets.append(card)

        if reflow:
            self._reflow_badges(force=True)

    def add_badge(self, text, bg_col="#1e1e1e", text_col="#dedede", reflow=True):
        self.add_stat_card("INFO", text, bg_col, text_col, reflow=reflow)

    def _on_inspector_resize(self, event=None):
        if not getattr(self, "inspected_data", None):
            self.show_inspector_placeholder()
        else:
            tb = getattr(self.inspector_text, "_textbox", self.inspector_text)
            cur_w = tb.winfo_width()
            last_w = getattr(self, "_last_inspector_w", None)
            self._reflow_badges()
            if last_w is None or abs(cur_w - last_w) > 30:
                self._last_inspector_w = cur_w
                self._update_inspector_tabs()
                if getattr(self, "inspected_path", None) and not getattr(self, "raw_json_mode", False):
                    self._render_inspection(self.inspected_data, self.inspected_path)

    def show_inspector_placeholder(self):
        self.clear_badges()
        tb = getattr(self.inspector_text, "_textbox", self.inspector_text)
        tb.configure(state="normal")
        tb.delete("1.0", "end")
        h = tb.winfo_height()
        top_pad = max(20, (h - 26) // 2) if h > 50 else 100
        tb.tag_configure("ph_text", font=("SF Pro Text", 12), foreground="#8e8e9a", justify="center", spacing1=top_pad)
        tb.insert("end", "Drop a file to inspect metadata\n\nor click 'Choose File...' above", "ph_text")
        tb.configure(state="disabled")

    def inspect_file(self, filepath):
        filepath = clean_file_path(filepath)
        if not os.path.exists(filepath): return
        self.inspected_path = filepath
        self.tabview.set("Media Inspector")

        self._inspect_id = getattr(self, "_inspect_id", 0) + 1
        current_id = self._inspect_id

        if hasattr(self, "_inspect_load_job") and self._inspect_load_job:
            try: self.root.after_cancel(self._inspect_load_job)
            except Exception: pass
            self._inspect_load_job = None

        def show_loading():
            if getattr(self, "_inspect_id", 0) == current_id:
                self.clear_badges()
                self.inspector_text.configure(state="normal")
                self.inspector_text.delete("1.0", "end")
                self.inspector_text.insert("1.0", f"\n  Analyzing media structure for: {os.path.basename(filepath)}...\n")
                self.inspector_text.configure(state="disabled")

        self._inspect_load_job = self.root.after(500, show_loading)

        def worker():
            cmd = [
                FFPROBE_BIN, "-v", "error",
                "-show_format", "-show_streams", "-show_chapters",
                "-of", "json",
                filepath
            ]
            try:
                res = subprocess.run(cmd, capture_output=True, text=True, errors="replace", timeout=12)
                if res.returncode == 0 and res.stdout.strip():
                    data = json.loads(res.stdout)
                    def on_done():
                        if getattr(self, "_inspect_id", 0) == current_id:
                            if hasattr(self, "_inspect_load_job") and self._inspect_load_job:
                                try: self.root.after_cancel(self._inspect_load_job)
                                except Exception: pass
                                self._inspect_load_job = None
                            self._render_inspection(data, filepath)
                    self.root.after(0, on_done)
                else:
                    err = res.stderr.strip() or "Unknown ffprobe analysis error"
                    def on_fail():
                        if getattr(self, "_inspect_id", 0) == current_id:
                            if hasattr(self, "_inspect_load_job") and self._inspect_load_job:
                                try: self.root.after_cancel(self._inspect_load_job)
                                except Exception: pass
                                self._inspect_load_job = None
                            self._render_inspection_error(err)
                    self.root.after(0, on_fail)
            except Exception as e:
                def on_err():
                    if getattr(self, "_inspect_id", 0) == current_id:
                        if hasattr(self, "_inspect_load_job") and self._inspect_load_job:
                            try: self.root.after_cancel(self._inspect_load_job)
                            except Exception: pass
                            self._inspect_load_job = None
                        self._render_inspection_error(str(e))
                self.root.after(0, on_err)

        threading.Thread(target=worker, daemon=True).start()

    def _update_inspector_tabs(self, event=None):
        try:
            tb = getattr(self.inspector_text, "_textbox", self.inspector_text)
            w = tb.winfo_width()
            col_gap = 135  # Exactly identical gap between data title and data for both columns
            c1_val = 145
            if w > 560:
                half = max(c1_val + 175, w // 2)
                c2_lbl = half - 15
                c2_val = c2_lbl + col_gap
                tb.configure(tabs=(c1_val, c2_lbl, c2_val))
                return (c1_val, c2_lbl, c2_val)
            else:
                tb.configure(tabs=(c1_val,))
                return (c1_val,)
        except Exception:
            return (145, 345, 480)

    def _render_inspection(self, data, filepath):
        self.inspected_data = data

        def _to_num(val, default=0):
            try: return float(val) if (val and str(val).strip() != "N/A") else default
            except (ValueError, TypeError): return default

        fmt = data.get("format", {})
        streams = data.get("streams", [])
        raw_dur = _to_num(fmt.get("duration", 0))

        v_streams, img_streams = [], []
        for s in streams:
            if s.get("codec_type") == "video":
                disp = s.get("disposition", {}) or {}
                is_pic = disp.get("attached_pic") == 1
                if is_pic or (s.get("codec_name") in ("mjpeg", "png", "jpeg") and raw_dur <= 0.05):
                    img_streams.append(s)
                else:
                    v_streams.append(s)
            elif s.get("codec_type") == "attachment":
                img_streams.append(s)

        a_streams = [s for s in streams if s.get("codec_type") == "audio"]
        s_streams = [s for s in streams if s.get("codec_type") == "subtitle"]

        if raw_dur <= 0 and v_streams:
            raw_dur = _to_num(v_streams[0].get("duration", 0))

        duration = raw_dur
        dur_str = format_time_duration(duration, force_hours=(duration >= 3600))
        size_bytes = int(_to_num(fmt.get("size", 0)) or (os.path.getsize(filepath) if os.path.exists(filepath) else 0))
        bitrate_overall = int(_to_num(fmt.get("bit_rate", 0)))

        _, ext = os.path.splitext(filepath.lower())
        is_image = (
            ext in (".jpg", ".jpeg", ".png", ".tiff", ".tif", ".webp", ".heic", ".bmp", ".gif", ".dng", ".cr2", ".nef", ".arw")
            or "image2" in fmt.get("format_name", "")
            or (len(v_streams) == 0 and len(img_streams) > 0 and len(a_streams) == 0)
        )
        is_audio = (
            ext in (".mp3", ".wav", ".aac", ".m4a", ".flac", ".aiff", ".aif", ".ogg", ".wma", ".opus", ".m4r")
            or (len(v_streams) == 0 and len(a_streams) > 0)
        )
        can_queue = (ext in SUPPORTED_EXTENSIONS) and (len(v_streams) > 0) and not is_image and not is_audio
        self.btn_inspect_to_queue.configure(state="normal" if can_queue else "disabled")

        # Generate Punchy HUD Quick Stat Cards (Data on the Left of Title)
        self.clear_badges()
        cards = []

        if v_streams:
            v0 = v_streams[0]
            # 1. Resolution - Accent Highlight
            w0 = v0.get("width", 0)
            h0 = v0.get("height", 0)
            lbl0 = get_common_resolution_label(w0, h0).strip(" ()")
            res_val = f"{lbl0} ({w0}x{h0})" if (lbl0 and w0 and h0) else (f"{w0}x{h0}" if (w0 and h0) else "N/A")
            cards.append(("Resolution", res_val, ULTRA_BG, ULTRA_TEXT, ULTRA_BORDER))

            # 2. Bitrate - Sky Blue
            v_br = fmt.get("bit_rate") or v0.get("bit_rate") or v0.get("tags", {}).get("bps") or v0.get("tags", {}).get("BPS")
            br_val = format_bitrate_str(v_br) if v_br else "N/A"
            cards.append(("Bitrate", br_val, "#0c2229", "#38bdf8", "#154352"))

            # 3. Frame Rate - Emerald Green
            fps0 = parse_stream_fps_val(v0)
            fr_mode = get_frame_rate_mode(v0)
            mode_short = "CFR" if "CFR" in fr_mode else ("VFR" if "VFR" in fr_mode else "")
            fps_val = (f"{fps0:.2f} FPS" + (f" ({mode_short})" if mode_short else "")) if fps0 else "N/A"
            cards.append(("Frame Rate", fps_val, "#0b2418", "#34d399", "#144d32"))

            # 4. Color & Depth - Gold for HDR, Purple for SDR
            pix_fmt = v0.get("pix_fmt", "")
            chroma0, bit_depth0 = analyze_pix_fmt(pix_fmt, v0.get("bits_per_raw_sample"))
            cprim = v0.get("color_primaries")
            cp_disp = "BT.709" if (cprim and "709" in cprim) else ("BT.2020" if (cprim and "2020" in cprim) else (cprim.upper() if cprim and cprim not in ("N/A", "unknown") else "SDR"))
            c_trc = str(v0.get("color_transfer", "")).lower()
            is_hdr = any(k in c_trc for k in ("smpte2084", "pq", "arib-std-b67", "hlg"))
            if is_hdr:
                color_val = f"{cp_disp} HDR • {bit_depth0}"
                cards.append(("Color / HDR", color_val, "#291a07", "#fbbf24", "#57380f"))
            else:
                cd_parts = [cp_disp]
                if bit_depth0 and bit_depth0 != "N/A": cd_parts.append(bit_depth0)
                if chroma0 and chroma0 != "N/A": cd_parts.append(chroma0)
                color_val = " • ".join(cd_parts)
                cards.append(("Color Space", color_val, "#1c162b", "#c084fc", "#3b2b5c"))

            # 5. Audio - Indigo
            if a_streams:
                a0 = a_streams[0]
                ac0 = a0.get("codec_name", "").upper()
                sr0 = a0.get("sample_rate")
                sr_k = f"{float(sr0)/1000.0:.0f}k" if sr0 else ""
                try: ch0 = int(a0.get("channels", 2) or 2)
                except Exception: ch0 = 2
                ch_str = "Mono" if ch0 == 1 else ("Stereo" if ch0 == 2 else f"{ch0}Ch")
                a_parts = [ac0] if ac0 else []
                if ch_str: a_parts.append(ch_str)
                if sr_k: a_parts.append(sr_k)
                audio_val = " • ".join(a_parts) or "Audio Stream"
                cards.append(("Audio", audio_val, "#141a29", "#818cf8", "#233252"))
            else:
                cards.append(("Audio", "No Audio Track", "#18191c", "#9ca3af", "#2e3036"))

            # 6. File Size - Neutral Graphite
            dur_short = format_time_duration(duration) if duration > 0 else ""
            sz_str = format_bytes_size_str(size_bytes).split(" (")[0] if size_bytes else "N/A"
            size_val = f"{sz_str} ({dur_short})" if dur_short else sz_str
            cards.append(("File Size", size_val, "#18191c", "#e2e8f0", "#2e3036"))

        elif is_image and (img_streams or v_streams):
            im0 = (img_streams or v_streams)[0]
            w0 = im0.get("width", 0)
            h0 = im0.get("height", 0)
            mp = round((w0 * h0) / 1_000_000.0, 1) if (w0 and h0) else 0
            c_name = im0.get("codec_name", "IMAGE").upper()
            pix_fmt = im0.get("pix_fmt", "")
            chroma0, bit_depth0 = analyze_pix_fmt(pix_fmt, im0.get("bits_per_raw_sample"))
            dar = im0.get("display_aspect_ratio") or (f"{round(w0/h0, 2)}:1" if (w0 and h0) else "")
            sz_str = format_bytes_size_str(size_bytes).split(" (")[0] if size_bytes else "N/A"

            cards.append(("Resolution", f"{mp} MP ({w0}x{h0})" if mp > 0 else (f"{w0}x{h0}" if (w0 and h0) else "N/A"), ULTRA_BG, ULTRA_TEXT, ULTRA_BORDER))
            cards.append(("Format", c_name, "#0c2229", "#38bdf8", "#154352"))
            cards.append(("Color Depth", f"{bit_depth0} ({pix_fmt})" if bit_depth0 != "N/A" else pix_fmt, "#1c162b", "#c084fc", "#3b2b5c"))
            cards.append(("Chroma", chroma0 if chroma0 != "N/A" else "Standard", "#0b2418", "#34d399", "#144d32"))
            cards.append(("Aspect Ratio", dar or "N/A", "#141a29", "#818cf8", "#233252"))
            cards.append(("File Size", sz_str, "#18191c", "#e2e8f0", "#2e3036"))

        elif a_streams:
            a0 = a_streams[0]
            ac0 = a0.get("codec_name", "").upper()
            lossless = any(c in ac0.lower() for c in ("pcm", "flac", "alac", "truehd", "wavpack", "ape"))
            a_br = a0.get("bit_rate") or a0.get("tags", {}).get("bps") or fmt.get("bit_rate")
            sr0 = a0.get("sample_rate")
            sr_k = f"{float(sr0)/1000.0:.1f} kHz" if sr0 else ""
            try: ch0 = int(a0.get("channels", 2) or 2)
            except Exception: ch0 = 2
            layout = a0.get("channel_layout") or ("Mono" if ch0 == 1 else ("Stereo" if ch0 == 2 else f"{ch0} Ch"))
            dur_short = format_time_duration(duration) if duration > 0 else ""
            sz_str = format_bytes_size_str(size_bytes).split(" (")[0] if size_bytes else "N/A"

            cards.append(("Audio Format", f"{ac0} {'(Lossless)' if lossless else ''}".strip(), ULTRA_BG, ULTRA_TEXT, ULTRA_BORDER))
            cards.append(("Bitrate", "Lossless" if lossless else (format_bitrate_str(a_br) if a_br else "N/A"), "#0c2229", "#38bdf8", "#154352"))
            cards.append(("Sample Rate", sr_k or "N/A", "#0b2418", "#34d399", "#144d32"))
            cards.append(("Channels", str(layout), "#1c162b", "#c084fc", "#3b2b5c"))
            cards.append(("Duration", dur_short or "N/A", "#141a29", "#818cf8", "#233252"))
            cards.append(("File Size", sz_str, "#18191c", "#e2e8f0", "#2e3036"))

        for c_title, c_val, c_bg, c_fg, c_border in cards:
            self.add_stat_card(c_title, c_val, c_bg, c_fg, c_border, reflow=False)
        self._reflow_badges(force=True)

        if hasattr(self, "_reflow_job") and self._reflow_job:
            try:
                self.root.after_cancel(self._reflow_job)
            except Exception:
                pass
        self._reflow_job = self.root.after(50, lambda: self._reflow_badges(force=True))

        sections = []

        # 1. GENERAL
        tags = {str(k).lower(): v for k, v in fmt.get("tags", {}).items()}
        c_date = format_date_str(tags.get("creation_time") or tags.get("encoded_date") or tags.get("date"))
        w_app = tags.get("encoder") or tags.get("writing_application")
        gen_items = []
        if bitrate_overall > 0:
            gen_items.append(("Bitrate", format_bitrate(bitrate_overall)))
        if size_bytes > 0:
            gen_items.append(("File Size", f"{format_bytes(size_bytes)} ({size_bytes:,} bytes)"))
        if duration > 0:
            gen_items.append(("Duration", f"{dur_str} ({duration:.2f} s)"))
        c_name = fmt.get('format_long_name', fmt.get('format_name', 'Unknown'))
        if 'QuickTime' in c_name or 'mov' in str(fmt.get('format_name', '')).lower():
            _, f_ext = os.path.splitext(filepath.lower())
            m_brand = str(tags.get('major_brand', '')).strip().lower()
            c_brands = str(tags.get('compatible_brands', '')).strip().lower()
            if f_ext == '.mp4' or any(b in m_brand or b in c_brands for b in ('isom', 'mp4', 'iso2', 'avc1')):
                c_name = 'MPEG-4 / MP4'
            elif f_ext == '.m4v' or 'm4v' in m_brand:
                c_name = 'Apple M4V'
            elif f_ext == '.mov' or m_brand == 'qt  ':
                c_name = 'QuickTime / MOV'
        gen_items.append(("Container", c_name))
        if c_date:
            gen_items.append(("Creation Date", str(c_date)))
        if w_app:
            gen_items.append(("Writing App", str(w_app)))
        sections.append(("GENERAL", [x for x in gen_items if x[1]]))

        # 2. IMAGE OR VIDEO
        if is_image:
            all_img = img_streams if img_streams else v_streams
            if all_img:
                s0 = all_img[0]
                c_name = s0.get("codec_name", "IMAGE").upper()
                w, h = s0.get("width", 0), s0.get("height", 0)
                dar = s0.get("display_aspect_ratio") or (f"{round(w/h, 3)}:1" if h > 0 else "")
                pix_fmt = s0.get("pix_fmt", "unknown")
                chroma, bit_depth = analyze_pix_fmt(pix_fmt, s0.get("bits_per_raw_sample"))
                img_items = [
                    ("Dimensions", f"{w} x {h}"),
                    ("Format", c_name),
                    ("Bit Depth", f"{bit_depth} ({pix_fmt})"),
                    ("Color Space", s0.get("color_space")),
                    ("Aspect Ratio", dar if dar else None),
                    ("Chroma Sampling", chroma),
                ]
                sections.append(("IMAGE PROPERTIES", [x for x in img_items if x[1]]))
        else:
            for idx, s in enumerate(v_streams):
                codec = s.get("codec_name", "unknown").upper()
                profile = s.get("profile", "")
                level = s.get("level", "")
                full_codec = f"{codec} ({profile}{f'@L{level}' if level and level != -99 else ''})" if profile else codec

                w, h = s.get("width", 0), s.get("height", 0)
                dar = s.get("display_aspect_ratio", "")
                if not dar and w > 0 and h > 0:
                    dar = f"{round(w / h, 2)}:1"
                res_label = get_common_resolution_label(w, h)

                fps_str = s.get("r_frame_rate", "0/0")
                if "/" in fps_str:
                    n, d = fps_str.split("/", 1)
                    try: fps_val = float(n) / float(d) if float(d) > 0 else 0
                    except: fps_val = 0
                else: fps_val = float(fps_str or 0)
                fr_mode = get_frame_rate_mode(s)

                pix_fmt = s.get("pix_fmt", "unknown")
                chroma, bit_depth = analyze_pix_fmt(pix_fmt, s.get("bits_per_raw_sample"))
                v_tags = {str(k).lower(): v for k, v in s.get("tags", {}).items()}
                v_bitrate = int(_to_num(s.get("bit_rate") or v_tags.get("bps") or v_tags.get("bps-eng", 0)))

                c_range = s.get("color_range", "unspecified")
                c_prim = s.get("color_primaries", "unspecified")
                c_trc = s.get("color_transfer", "unspecified")
                c_space = s.get("color_space", "unspecified")

                v_items = [
                    ("Codec / Profile", full_codec),
                    ("Resolution", f"{w} x {h}{res_label}"),
                    ("Bitrate", format_bitrate(v_bitrate) if v_bitrate > 0 else None),
                    ("Frame Rate", f"{fps_val:.3f} fps ({fr_mode})"),
                    ("Aspect Ratio", dar if dar else None),
                    ("Bit Depth", f"{bit_depth} ({pix_fmt})"),
                    ("Chroma Sampling", chroma),
                    ("Matrix / Space", c_space if c_space != "unspecified" else None),
                ]

                for sd in s.get("side_data_list", []):
                    sd_type = sd.get("side_data_type", "")
                    if "Mastering display" in sd_type:
                        v_items.append(("HDR Mastering", f"SMPTE 2086 (L:{sd.get('min_luminance')}-{sd.get('max_luminance')})"))
                    elif "Content light level" in sd_type:
                        v_items.append(("HDR Light Level", f"MaxCLL={sd.get('max_content', 0)} cd/m², MaxFALL={sd.get('max_average', 0)} cd/m²"))

                sections.append((f"VIDEO STREAM #{idx + 1}", [x for x in v_items if x[1]]))

            for idx, s in enumerate(a_streams):
                acodec = s.get("codec_name", "unknown").upper()
                profile = s.get("profile", "")
                try: ch = int(s.get("channels", 2) or 2)
                except (ValueError, TypeError): ch = 2
                raw_layout = s.get("channel_layout")
                if not raw_layout or str(raw_layout).strip().lower() in ("unknown", "unspecified"):
                    l_map = {1: "mono", 2: "stereo", 3: "2.1", 4: "4.0", 5: "5.0", 6: "5.1", 8: "7.1"}
                    layout = l_map.get(ch, f"{ch} ch")
                else:
                    layout = raw_layout
                sr = s.get("sample_rate", "48000")
                stags = {str(k).lower(): v for k, v in s.get("tags", {}).items()}
                a_br = int(_to_num(s.get("bit_rate") or stags.get("bps") or stags.get("bps-eng", 0)))

                ch_str = f"1 Channel ({layout})" if ch == 1 else f"{ch} Channels ({layout})"
                a_items = [
                    ("Codec", f"{acodec} ({profile})" if profile else acodec),
                    ("Bitrate", format_bitrate(a_br) if a_br > 0 else None),
                    ("Channels", ch_str),
                    ("Sample Rate", f"{float(sr)/1000.0:.1f} kHz"),
                    ("Language", stags.get("language")),
                    ("Title", stags.get("title")),
                ]
                sections.append((f"AUDIO STREAM #{idx + 1}", [x for x in a_items if x[1]]))

            if s_streams:
                sub_items = []
                for idx, s in enumerate(s_streams):
                    stags = {str(k).lower(): v for k, v in s.get("tags", {}).items()}
                    lang = stags.get("language", "und")
                    title = stags.get("title", s.get("codec_name", "text"))
                    sub_items.append((f"Stream #{idx + 1}", f"{title} ({lang}) [{s.get('codec_name', '').upper()}]"))
                sections.append(("SUBTITLES", sub_items))

            if img_streams:
                att_items = []
                for idx, s in enumerate(img_streams):
                    att_items.append((f"Item #{idx + 1}", f"{s.get('codec_name', 'image').upper()} ({s.get('width', 0)}x{s.get('height', 0)})"))
                sections.append(("ATTACHMENTS / EMBEDDED COVERS", att_items))

        tb = getattr(self.inspector_text, "_textbox", self.inspector_text)
        tb.configure(state="normal")
        tb.delete("1.0", "end")

        self._update_inspector_tabs()

        tb.tag_configure("sec_h", font=("SF Pro Display", 12, "bold"), foreground=ULTRA_TEXT, spacing1=12, spacing3=5)
        tb.tag_configure("lbl", font=("SF Pro Text", 11), foreground=TEXT_MUTED, spacing1=3, spacing3=3)
        tb.tag_configure("val", font=("SF Pro Text", 11, "bold"), foreground=TEXT_PRIMARY, spacing1=3, spacing3=3)

        for sec_idx, (sec_title, items) in enumerate(sections):
            if not items:
                continue
            if sec_idx > 0:
                tb.insert("end", "\n")
            tb.insert("end", f"  ●  {sec_title}\n\n", "sec_h")

            i = 0
            while i < len(items):
                lbl1, val1 = items[i]
                is_wide1 = len(str(val1)) > 30 or len(str(lbl1)) > 17
                if is_wide1 or i + 1 >= len(items):
                    tb.insert("end", f"  {lbl1}\t", "lbl")
                    tb.insert("end", f"{val1}\n", "val")
                    i += 1
                else:
                    lbl2, val2 = items[i + 1]
                    is_wide2 = len(str(val2)) > 30 or len(str(lbl2)) > 17
                    if is_wide2:
                        tb.insert("end", f"  {lbl1}\t", "lbl")
                        tb.insert("end", f"{val1}\n", "val")
                        i += 1
                    else:
                        tb.insert("end", f"  {lbl1}\t", "lbl")
                        tb.insert("end", f"{val1}\t", "val")
                        tb.insert("end", f"{lbl2}\t", "lbl")
                        tb.insert("end", f"{val2}\n", "val")
                        i += 2

        tb.configure(state="disabled")
        self.inspector_scroller.sync_position()

    def _render_inspection_error(self, err):
        self.clear_badges()
        self.inspector_text.configure(state="normal")
        self.inspector_text.delete("1.0", "end")
        self.inspector_text.insert("1.0", f"\n❌ Failed to inspect file metadata:\n\n{err}\n")
        self.inspector_text.configure(state="disabled")

    def _render_raw_json(self):
        if not self.inspected_data: return
        self.inspector_text.configure(state="normal")
        self.inspector_text.delete("1.0", "end")
        self.inspector_text.insert("1.0", json.dumps(self.inspected_data, indent=2))
        self.inspector_text.configure(state="disabled")
        self.inspector_scroller.sync_position()

    def toggle_raw_json(self):
        self.raw_json_mode = not self.raw_json_mode
        self.btn_inspect_raw.configure(
            text="Clean View" if self.raw_json_mode else "Raw JSON",
            fg_color="#143e25" if self.raw_json_mode else NEUTRAL_BTN
        )
        if self.inspected_data and self.inspected_path:
            if self.raw_json_mode:
                self._render_raw_json()
            else:
                self._render_inspection(self.inspected_data, self.inspected_path)

    def browse_inspect_file(self):
        f = filedialog.askopenfilename(
            title="Select File to Inspect",
            filetypes=[("All Media Files", " ".join(f"*{x}" for x in INSPECTOR_EXTENSIONS)), ("All Files", "*.*")]
        )
        if f: self.inspect_file(f)

    def send_inspected_to_queue(self):
        if self.inspected_path and os.path.exists(self.inspected_path):
            _, ext = os.path.splitext(self.inspected_path.lower())
            if ext not in SUPPORTED_EXTENSIONS:
                messagebox.showinfo("Unsupported Format", "Only supported video files can be added to the queue.")
                return
            self.handle_incoming_files([self.inspected_path])
            self.tabview.set("Batch Queue")

    def copy_inspector_summary(self):
        try:
            content = self.inspector_text.get("1.0", "end").strip()
            if content:
                self.root.clipboard_clear()
                self.root.clipboard_append(content)
                self.btn_inspect_copy.configure(text="✔ Copied!")
                self.root.after(1400, lambda: self.btn_inspect_copy.configure(text="Copy Summary"))
        except Exception: pass

    def inspect_queued_item(self, item_id):
        with self.queue_lock:
            item = self.items_by_id.get(item_id)
            if item and os.path.exists(item["path"]):
                self.inspect_file(item["path"])

    def _on_active_scrollbar_drag(self, *args):
        self.active_jobs_canvas.yview(*args)
        self.active_jobs_canvas.scroller.sync_position()

    def _on_active_jobs_scroll_update(self, first, last):
        self.active_jobs_scrollbar.set(first, last)

    def _on_queue_scrollbar_drag(self, *args):
        self.canvas_queue.yview(*args)
        self.canvas_queue.scroller.sync_position()

    def _on_tab_changed(self, *args):
        try:
            if self.tabview.get() == "Live Console":
                self.log_text.see("end")
            elif self.tabview.get() == "Media Inspector":
                if hasattr(self, "_reflow_badges"):
                    self._reflow_badges(force=True)
                if hasattr(self, "inspector_scroller"):
                    self.inspector_scroller.sync_position()
        except Exception: pass

    def mark_custom_settings(self):
        if not self._preset_loading and not getattr(self, "_loading_selection_settings", False):
            self.preset_var.set("Custom")
            self.save_last_preset_choice("Custom")
            try:
                settings = self.get_current_settings()
                self.presets["Custom"] = {
                    "codec": settings.get("codec", "HEVC (H.265)"),
                    "encoder": settings["encoder"],
                    "chroma": settings["chroma"],
                    "quality": str(int(round(float(settings["quality"])))),
                    "quality_encoder": settings.get("quality_encoder", settings["encoder"]),
                    "denoise": str(settings["denoise"])
                }
                self.save_presets_to_disk()
            except Exception:
                pass
            self.update_settings_summary()
            self.apply_settings_to_selected()

    def refresh_preset_dropdown(self, select_preset=None):
        keys = list(self.presets.keys())
        self.preset_cb.configure(values=keys)
        if select_preset and select_preset in keys: self.preset_var.set(select_preset)
        elif self.preset_var.get() not in keys: self.preset_var.set("Custom")

    def save_current_as_preset(self):
        dialog = ctk.CTkInputDialog(text="Enter preset name:", title="Save Preset")
        def _trigger_ok(event=None):
            try: dialog._ok_event()
            except Exception: pass
            return "break"
        for key_seq in ("<Return>", "<KP_Enter>"):
            dialog.bind(key_seq, _trigger_ok)
            if hasattr(dialog, "_entry"): dialog._entry.bind(key_seq, _trigger_ok)
        preset_name = dialog.get_input()
        if not preset_name or not preset_name.strip(): return
        preset_name = preset_name.strip()
        if preset_name in DEFAULT_PRESETS and preset_name != "Custom":
            messagebox.showerror("Error", f"'{preset_name}' is a built-in default preset.")
            return

        settings = self.get_current_settings()
        self.presets[preset_name] = {
            "codec": settings.get("codec", "HEVC (H.265)"),
            "encoder": settings["encoder"],
            "chroma": settings["chroma"],
            "quality": str(int(round(float(settings["quality"])))),
            "quality_encoder": settings.get("quality_encoder", settings["encoder"]),
            "denoise": str(settings["denoise"])
        }
        self.save_presets_to_disk()
        self.save_last_preset_choice(preset_name)
        self.refresh_preset_dropdown(select_preset=preset_name)

    def delete_selected_preset(self):
        name = self.preset_var.get()
        if name in DEFAULT_PRESETS:
            messagebox.showinfo("Protected", "Cannot delete built-in presets.")
            return
        if messagebox.askyesno("Delete Preset", f"Delete preset '{name}'?"):
            if name in self.presets:
                del self.presets[name]
                self.save_presets_to_disk()
                self.refresh_preset_dropdown(select_preset="Log Footage")
                self.on_preset_change("Log Footage")

    def update_active_jobs_layout(self):
        count = self.active_jobs_canvas.job_count()
        target_height = getattr(self, "active_jobs_height", int(3.5 * QuartzActiveJobsCanvas.ROW_STEP) + 4)
        if not self.active_jobs_wrap.winfo_ismapped():
            self.active_jobs_wrap.pack(fill="x", padx=10, pady=(0, 10))
        total_content_h = count * QuartzActiveJobsCanvas.ROW_STEP + 4
        if total_content_h > target_height:
            if not self.active_jobs_scrollbar.winfo_ismapped():
                self.active_jobs_scrollbar.pack(side="right", fill="y", pady=0, before=self.active_jobs_canvas)
        else:
            if self.active_jobs_scrollbar.winfo_ismapped():
                self.active_jobs_scrollbar.pack_forget()
        self.active_jobs_canvas.configure(height=target_height)
        self.active_jobs_scrollbar.configure(height=target_height)
        self.active_jobs_canvas.redraw_all()

    def _process_ui_queue(self):
        try:
            logs_buffer = []
            progress_updates = {}
            jobs_to_start = []
            jobs_to_end = {}
            latest_state = None
            refresh_stats = False

            for _ in range(400):
                if self.ui_queue.empty(): break
                event_type, payload = self.ui_queue.get_nowait()
                if event_type == "log": logs_buffer.append(payload)
                elif event_type == "job_start": jobs_to_start.append(payload)
                elif event_type == "job_end":
                    if isinstance(payload, (list, tuple)):
                        jobs_to_end[payload[0]] = payload[1]
                    else:
                        jobs_to_end[payload] = False
                elif event_type == "progress":
                    item_id, pdata = payload
                    progress_updates[item_id] = pdata
                elif event_type == "app_state": latest_state = payload
                elif event_type == "item_status":
                    item_id = payload[0]
                    status = payload[1]
                    ptext = payload[2] if len(payload) > 2 else None
                    rstats = payload[3] if len(payload) > 3 else False
                    dstats = payload[4] if len(payload) > 4 else None
                    with self.queue_lock:
                        item = self.items_by_id.get(item_id)
                        if item:
                            item["status"] = status
                            item["progress_text"] = ptext
                            if dstats is not None:
                                item["done_stats"] = dstats
                    self.canvas_queue.update_item_status(item_id, status, ptext, done_stats=dstats)
                    if rstats: refresh_stats = True
                elif event_type == "refresh_queue":
                    with self.queue_lock: items_snapshot = list(self.queue_items)
                    self.canvas_queue.set_items(items_snapshot)
                    refresh_stats = True
                elif event_type == "refresh_stats": refresh_stats = True

            for (item_id, display_title, tag) in jobs_to_start:
                self.active_jobs_canvas.start_job(item_id, display_title, tag)

            for item_id, (pct, t_str, s_str, f_str, eta_str) in progress_updates.items():
                self.active_jobs_canvas.update_progress(item_id, pct, t_str, s_str, f_str, eta_str)

            for item_id, is_completed in jobs_to_end.items():
                self.active_jobs_canvas.end_job(item_id, completed=is_completed)

            if jobs_to_start or jobs_to_end:
                self.update_active_jobs_layout()

            if latest_state is not None: self._apply_app_state(latest_state)
            if refresh_stats or progress_updates: self._update_queue_stats()

            if logs_buffer:
                combined_text = "".join(logs_buffer)
                is_console_visible = (self.tabview.get() == "Live Console")
                was_at_bottom = True
                if is_console_visible:
                    tb = getattr(self.log_text, "_textbox", None)
                    if tb and tb.winfo_ismapped():
                        try:
                            _, y_bot = tb.yview()
                            was_at_bottom = (y_bot >= 0.985)
                        except Exception: was_at_bottom = True

                self.log_text.insert("end", combined_text)
                line_count = int(self.log_text.index("end-1c").split(".")[0])
                if line_count > 2500:
                    self.log_text.delete("1.0", "400.0")
                    self.log_scroller.sync_position()
                    if was_at_bottom: self.log_text.see("end")

                if is_console_visible and was_at_bottom and not self.log_scroller.is_animating:
                    self.log_text.see("end")
        except Exception: pass
        finally:
            self.root.after(30, self._process_ui_queue)

    def _apply_app_state(self, state):
        if state == "encoding":
            self.status_badge.configure(text="● ENCODING", text_color=ULTRA_TEXT, fg_color=ULTRA_BG)
            self.btn_cancel.configure(state="normal")
            self.update_action_button_ui()
        elif state == "paused":
            self.status_badge.configure(text="❚❚ PAUSED", text_color=HOLD_TEXT, fg_color=HOLD_BG)
            self.btn_cancel.configure(state="normal")
            self.update_action_button_ui()
        elif state == "idle":
            self.status_badge.configure(text="● IDLE", text_color=DONE_GREEN, fg_color=DONE_BG)
            self.btn_cancel.configure(state="disabled")
            self.update_action_button_ui()

    def append_log(self, text):
        now_ts = time.strftime("[%H:%M:%S] ")
        lines = text.splitlines(True)
        formatted_lines = []
        for line in lines:
            if line.strip() and not line.startswith(" ") and not line.startswith("	"):
                formatted_lines.append(f"{now_ts}{line}")
            else:
                formatted_lines.append(line)
        formatted = "".join(formatted_lines)
        with LOG_LOCK:
            try:
                os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
                with open(LOG_FILE, "a", encoding="utf-8") as f:
                    f.write(formatted)
                self._log_bytes_written = getattr(self, "_log_bytes_written", 0) + len(formatted)
                if self._log_bytes_written >= 1024 * 1024:
                    rotate_log_file()
                    self._log_bytes_written = 0
            except Exception:
                pass
        self.ui_queue.put(("log", formatted))

    def update_progress_ui(self, item_id, pct, time_str, speed_str, fps_str, eta_str):
        self.last_pct_map[item_id] = float(pct)
        self.last_progress_map[item_id] = (pct, time_str, speed_str, fps_str, eta_str)
        self.ui_queue.put(("progress", (item_id, (pct, time_str, speed_str, fps_str, eta_str))))

    def update_item_status_ui(self, item_id, status, progress_text=None, refresh_stats=False, done_stats=None):
        self.ui_queue.put(("item_status", (item_id, status, progress_text, refresh_stats, done_stats)))

    def set_app_state(self, state):
        self.ui_queue.put(("app_state", state))

    def step_quality(self, delta):
        is_vt = (self.encoder_var.get() == "AppleMediaEngine")
        min_q, max_q = (1, 100) if is_vt else (0, 51)
        val = max(min_q, min(max_q, int(round(self.quality_slider.get())) + delta))
        if is_vt: self.last_vt_quality = val
        else: self.last_cpu_crf = val
        self.quality_slider.set(val)
        self.lbl_quality_val.configure(text=get_quality_description(val, self.encoder_var.get()))
        self.mark_custom_settings()

    def step_denoise(self, delta):
        val = max(0, min(30, int(round(self.denoise_slider.get())) + delta))
        self.denoise_slider.set(val)
        self.lbl_denoise_val.configure(text=get_denoise_description(val))
        self.mark_custom_settings()

    def step_concurrency(self, delta):
        modes = ["Sequential", "Balanced", "Turbo"]
        cur = getattr(self, "concurrency_mode", "Balanced")
        idx = modes.index(cur) if cur in modes else 1
        new_idx = max(0, min(len(modes) - 1, idx + delta))
        self.set_concurrency_mode(modes[new_idx])

    def edit_quality_dialog(self):
        is_vt = (self.encoder_var.get() == "AppleMediaEngine")
        if is_vt:
            dialog = ctk.CTkInputDialog(text="Enter VideoToolbox Quality (1 - 100):", title="Set Quality")
        else:
            dialog = ctk.CTkInputDialog(text="Enter Target CRF (0 - 51, lower is higher quality):", title="Set CRF")
        val_str = dialog.get_input()
        if val_str and val_str.strip():
            try:
                if is_vt:
                    val_int = max(1, min(100, int(val_str.strip())))
                    self.last_vt_quality = val_int
                    slider_val = val_int
                else:
                    crf_in = max(0, min(51, int(val_str.strip())))
                    slider_val = 51 - crf_in
                    self.last_cpu_crf = slider_val
                self.quality_slider.set(slider_val)
                self.lbl_quality_val.configure(text=get_quality_description(slider_val, self.encoder_var.get()))
                self.mark_custom_settings()
            except ValueError: pass

    def edit_denoise_dialog(self):
        dialog = ctk.CTkInputDialog(text="Enter Denoise strength (0 - 30):", title="Set Denoise")
        val_str = dialog.get_input()
        if val_str and val_str.strip():
            try:
                val_int = max(0, min(30, int(val_str.strip())))
                self.denoise_slider.set(val_int)
                self.lbl_denoise_val.configure(text=get_denoise_description(val_int))
                self.mark_custom_settings()
            except ValueError: pass

    def edit_concurrency_dialog(self):
        modes = ["Sequential", "Balanced", "Turbo"]
        cur = getattr(self, "concurrency_mode", "Balanced")
        idx = modes.index(cur) if cur in modes else 1
        new_idx = (idx + 1) % len(modes)
        self.set_concurrency_mode(modes[new_idx])

    def on_denoise_slider_change(self, value):
        val = int(round(float(value)))
        self.lbl_denoise_val.configure(text=get_denoise_description(val))

    def on_quality_slider_change(self, value):
        val = int(round(float(value)))
        if self.encoder_var.get() == "AppleMediaEngine": self.last_vt_quality = val
        else: self.last_cpu_crf = val
        self.lbl_quality_val.configure(text=get_quality_description(val, self.encoder_var.get()))

    def sync_encoder_ui(self):
        is_vt = (self.encoder_var.get() == "AppleMediaEngine")
        is_h264 = ("H.264" in self.codec_var.get())
        opts = ["8-Bit 4:2:0"] if is_h264 else (["10-Bit 4:2:2", "10-Bit 4:2:0", "8-Bit 4:2:0"] if (not is_vt or HAS_VT_422) else ["10-Bit 4:2:0", "8-Bit 4:2:0"])
        self.chroma_cb.configure(values=opts)
        if self.chroma_var.get() not in opts: self.chroma_var.set(opts[0])

        if is_vt:
            self.lbl_quality_title.configure(text="Quality")
            self.quality_slider.configure(from_=1, to=100, number_of_steps=99)
            self.quality_slider.set(self.last_vt_quality)
        else:
            self.lbl_quality_title.configure(text="Quality")
            self.quality_slider.configure(from_=0, to=51, number_of_steps=51)
            self.quality_slider.set(self.last_cpu_crf)

        val = int(round(self.quality_slider.get()))
        self.lbl_quality_val.configure(text=get_quality_description(val, self.encoder_var.get()))

    def on_codec_menu_change(self, choice=None):
        self.sync_encoder_ui()
        self.mark_custom_settings()

    def on_preset_change(self, choice=None):
        name = self.preset_var.get()
        if name in self.presets:
            self.save_last_preset_choice(name)
            self._preset_loading = True
            p = self.presets[name]
            self.codec_var.set(p.get("codec", "HEVC (H.265)"))
            self.current_encoder = p.get("encoder", "AppleMediaEngine")
            self.encoder_var.set(self.current_encoder)
            chroma_setting = p.get("chroma", DEFAULT_CHROMA)
            if not HAS_VT_422 and "4:2:2" in chroma_setting: chroma_setting = "10-Bit 4:2:0"
            self.chroma_var.set(chroma_setting)
            self.sync_encoder_ui()
            try: q_val = int(float(p.get("quality", 69)))
            except ValueError: q_val = 69
            q_enc = p.get("quality_encoder", p.get("encoder", "AppleMediaEngine"))
            if self.encoder_var.get() == "AppleMediaEngine":
                if q_enc == "CPU" and q_val <= 51:
                    q_val = max(1, min(100, int(round((q_val / 51.0) * 100))))
                self.last_vt_quality = q_val
            else:
                if q_enc == "AppleMediaEngine" or q_val > 51:
                    q_val = max(0, min(51, int(round((q_val / 100.0) * 51))))
                self.last_cpu_crf = q_val
            self.quality_slider.set(q_val)
            self.lbl_quality_val.configure(text=get_quality_description(q_val, self.encoder_var.get()))
            try:
                d_raw = float(p.get("denoise", 0))
                d_val = int(round(d_raw * 1000)) if 0.0 < d_raw < 1.0 else int(round(d_raw))
            except ValueError: d_val = 0
            self.denoise_slider.set(d_val)
            self.lbl_denoise_val.configure(text=get_denoise_description(d_val))
            self._preset_loading = False
            self.update_settings_summary()
            self.apply_settings_to_selected()

    def on_encoder_menu_change(self, choice=None):
        self.current_encoder = self.encoder_var.get()
        self.sync_encoder_ui()
        self.mark_custom_settings()

    def _on_key_press_option(self, event):
        if getattr(event, "keysym", "") in ("Alt_L", "Alt_R", "Option"):
            self._option_key_pressed = True
            self._sync_option_ui_state()

    def _on_key_release_option(self, event):
        if getattr(event, "keysym", "") in ("Alt_L", "Alt_R", "Option"):
            self._option_key_pressed = False
            self._sync_option_ui_state()

    def is_option_held(self, event=None):
        if event:
            state = getattr(event, "state", 0)
            if isinstance(state, int) and (state & 0x18):
                return True
            mods = str(getattr(event, "modifier", "")).lower()
            if "alt" in mods or "opt" in mods:
                return True
        if is_macos_option_held():
            return True
        return getattr(self, "_option_key_pressed", False)

    def _sync_option_ui_state(self):
        held = self.is_option_held()
        if hasattr(self, "canvas_queue"):
            self.canvas_queue.set_option_mode(held)

    def _poll_option_key(self):
        try:
            self._sync_option_ui_state()
        except Exception:
            pass
        finally:
            self.root.after(30, self._poll_option_key)

    def setup_drag_and_drop(self):
        if not HAS_TKDND or not getattr(self.root, "TkdndVersion", None):
            self.append_log("[INFO] Drag & Drop library unavailable; manual browse buttons active.\n")
            return

        def on_drop(event):
            try:
                raw_data = getattr(event, 'data', '')
                if raw_data:
                    try:
                        files = self.root.tk.splitlist(raw_data)
                    except Exception:
                        pattern = r'\{([^}]+)\}|(\S+)'
                        matches = re.findall(pattern, raw_data)
                        files = [m[0] or m[1] for m in matches] if matches else [raw_data]
                    cleaned_files = [clean_file_path(f) for f in files if clean_file_path(f)]
                    if not cleaned_files:
                        return "break"
                    if self.is_option_held(event) or (hasattr(self, "tabview") and self.tabview.get() == "Media Inspector"):
                        self.tabview.set("Media Inspector")
                        self.inspect_file(cleaned_files[0])
                    else:
                        self.handle_incoming_files(cleaned_files)
            except Exception as e:
                self.append_log(f"[ERROR] Drop processing error: {e}\n")
            return "break"

        def on_inspector_drop(event):
            try:
                raw_data = getattr(event, 'data', '')
                if raw_data:
                    try:
                        files = self.root.tk.splitlist(raw_data)
                    except Exception:
                        pattern = r'\{([^}]+)\}|(\S+)'
                        matches = re.findall(pattern, raw_data)
                        files = [m[0] or m[1] for m in matches] if matches else [raw_data]
                    cleaned_files = [clean_file_path(f) for f in files if clean_file_path(f)]
                    if cleaned_files:
                        self.tabview.set("Media Inspector")
                        self.inspect_file(cleaned_files[0])
            except Exception as e:
                self.append_log(f"[ERROR] Inspector drop error: {e}\n")
            return "break"

        raw_targets = [
            self.root,
            getattr(self, "canvas_queue", None),
            getattr(self, "log_text", None),
            getattr(getattr(self, "log_text", None), "_textbox", None),
            getattr(self, "settings_card", None),
            getattr(self, "active_jobs_canvas", None),
            getattr(self, "status_card", None)
        ]
        targets = [w for w in raw_targets if w is not None]
        for w in targets:
            try:
                w.drop_target_register(DND_FILES)
                w.dnd_bind('<<Drop>>', on_drop)
            except Exception:
                pass

        inspector_targets = [
            getattr(self, "tab_inspector", None),
            getattr(self, "inspector_text", None),
            getattr(getattr(self, "inspector_text", None), "_textbox", None)
        ]
        for iw in [w for w in inspector_targets if w is not None]:
            try:
                iw.drop_target_register(DND_FILES)
                iw.dnd_bind('<<Drop>>', on_inspector_drop)
            except Exception:
                pass
    def _on_dest_changed(self, event=None):
        if getattr(self, "_dest_debounce_job", None):
            try:
                self.root.after_cancel(self._dest_debounce_job)
            except Exception:
                pass
            self._dest_debounce_job = None
        new_dest = self.dest_var.get().strip()
        self.save_output_dir(new_dest)
        with self.queue_lock:
            for item in self.queue_items:
                if item.get("status") == "queued":
                    item["settings"]["dest_dir"] = os.path.expanduser(new_dest)
        self.apply_settings_to_selected()

    def _debounce_dest_change(self, *args):
        if getattr(self, "_dest_debounce_job", None):
            try:
                self.root.after_cancel(self._dest_debounce_job)
            except Exception:
                pass
        self._dest_debounce_job = self.root.after(350, self._on_dest_changed)

    def browse_dest(self):
        folder = filedialog.askdirectory(initialdir=self.dest_var.get())
        if folder:
            self.dest_var.set(folder)
            self._on_dest_changed()

    def get_current_settings(self):
        try:
            denoise_val = int(round(float(self.denoise_slider.get())))
        except Exception: denoise_val = 0

        try: q_val = int(round(float(self.quality_slider.get())))
        except Exception: q_val = 69 if self.encoder_var.get() == "AppleMediaEngine" else 33

        dest_dir = self.dest_var.get().strip() or os.path.expanduser("~/Desktop")
        return {
            "dest_dir": os.path.expanduser(dest_dir),
            "codec": self.codec_var.get(),
            "encoder": self.encoder_var.get(),
            "chroma": self.chroma_var.get(),
            "denoise": denoise_val,
            "quality": q_val,
            "quality_encoder": self.encoder_var.get(),
            "speed": "fast",
            "concurrency": getattr(self, "concurrency_mode", "Balanced"),
            "tag_settings": bool(getattr(self, "tag_settings", False))
        }

    def handle_incoming_files(self, files):
        job_settings = self.get_current_settings()
        with self.queue_lock: self.active_scans += 1

        def scan_worker(settings=job_settings):
            batch_chunk = []
            total_added = 0
            batch_seen = set()
            dest_dir = settings.get("dest_dir", os.path.expanduser("~/Desktop"))

            def flush_chunk():
                nonlocal batch_chunk, total_added
                if not batch_chunk: return
                start_dispatcher = False
                added_count = 0
                prepared_items = []
                for v_path, v_rel in batch_chunk:
                    if v_path in batch_seen: continue
                    batch_seen.add(v_path)
                    file_name = os.path.basename(v_path)
                    disp_name = os.path.join(v_rel, file_name) if v_rel else file_name

                    item_data = {
                        "path": v_path, "rel_dir": v_rel,
                        "filename": file_name, "display_name": disp_name,
                        "settings": settings, "status": "queued", "progress_text": None,
                        "done_stats": ""
                    }
                    prepared_items.append(item_data)

                with self.process_lock:
                    with self.queue_lock:
                        for item_data in prepared_items:
                            self.item_counter += 1
                            item_data["id"] = self.item_counter
                            self.queue_items.append(item_data)
                            self.items_by_id[self.item_counter] = item_data
                            added_count += 1

                        if not self.dispatcher_alive and not self.is_running and added_count > 0 and getattr(self, "auto_start", False):
                            self.dispatcher_alive = True
                            self.is_running = True
                            start_dispatcher = True

                batch_chunk = []
                if added_count > 0:
                    total_added += added_count
                    self.ui_queue.put(("refresh_queue", None))
                    if start_dispatcher:
                        self.set_app_state("encoding")
                        threading.Thread(target=self._batch_dispatcher, daemon=True).start()

            try:
                for f in files:
                    clean = clean_file_path(f)
                    if not clean: continue
                    if os.path.isdir(clean):
                        clean_abs = os.path.abspath(clean)
                        safe_top_folder = get_safe_output_folder(clean_abs, dest_dir)
                        for root_dir, _, filenames in os.walk(clean_abs):
                            sub_rel = os.path.relpath(root_dir, clean_abs)
                            folder_rel = safe_top_folder if sub_rel == "." else os.path.join(safe_top_folder, sub_rel)
                            for fname in sorted(filenames):
                                if fname.startswith("."): continue
                                if fname.lower().endswith(SUPPORTED_EXTENSIONS):
                                    abs_path = os.path.abspath(os.path.join(root_dir, fname))
                                    batch_chunk.append((abs_path, folder_rel))
                                    if len(batch_chunk) >= 50: flush_chunk()
                    elif os.path.isfile(clean):
                        if not os.path.basename(clean).startswith("."):
                            if clean.lower().endswith(SUPPORTED_EXTENSIONS):
                                abs_path = os.path.abspath(clean)
                                batch_chunk.append((abs_path, ""))
                                if len(batch_chunk) >= 50: flush_chunk()

                flush_chunk()
                if total_added > 0: self.append_log(f"[INFO] Added {total_added} file(s) to queue.\n")
            finally:
                with self.queue_lock: self.active_scans = max(0, self.active_scans - 1)

        threading.Thread(target=scan_worker, daemon=True).start()

    def remove_or_cancel_item(self, item_id):
        with self.queue_lock:
            item = self.items_by_id.get(item_id)
            if not item: return
            if item["status"] == "queued":
                self.queue_items.remove(item)
                self.items_by_id.pop(item_id, None)
                self.selected_queue_ids.discard(item_id)
                if getattr(self, "_selection_pivot_id", None) == item_id:
                    self._selection_pivot_id = None
                self.canvas_queue.set_items(self.queue_items)
                self.canvas_queue.set_selected_ids(self.selected_queue_ids)
                self.update_settings_header_label()
                self.update_settings_summary()
                self._update_queue_stats()
                return
        self.cancel_single_item(item_id)

    def cancel_single_item(self, item_id):
        with self.process_lock:
            self.cancelled_ids.add(item_id)
            self.suspended_ids.discard(item_id)
            self.retrying_ids.discard(item_id)
            self._last_hw_release_time = time.time()
            proc = self.active_processes.get(item_id)

        def terminate_job():
            if proc and proc.poll() is None:
                try:
                    safe_killpg(proc, signal.SIGCONT, signal.SIGTERM)
                    try:
                        proc.wait(timeout=0.4)
                    except Exception:
                        safe_killpg(proc, signal.SIGKILL)
                        try:
                            proc.wait(timeout=0.4)
                        except Exception:
                            pass
                except Exception: pass

        threading.Thread(target=terminate_job, daemon=True).start()

    def clear_completed_items(self):
        with self.queue_lock:
            self.queue_items = [q for q in self.queue_items if q["status"] not in ("completed", "failed", "cancelled")]
            self.items_by_id = {q["id"]: q for q in self.queue_items}
            remaining_ids = set(self.items_by_id.keys())
            self.last_pct_map = {k: v for k, v in self.last_pct_map.items() if k in remaining_ids}
            self.last_progress_map = {k: v for k, v in self.last_progress_map.items() if k in remaining_ids}
            items_snapshot = list(self.queue_items)
        self.canvas_queue.set_items(items_snapshot)
        self._update_queue_stats()

    def clear_queued_items(self):
        with self.queue_lock:
            removed_count = sum(1 for q in self.queue_items if q["status"] == "queued")
            self.queue_items = [q for q in self.queue_items if q["status"] != "queued"]
            self.items_by_id = {q["id"]: q for q in self.queue_items}
            self.selected_queue_ids.clear()
            self._selection_pivot_id = None
            items_snapshot = list(self.queue_items)
        self.canvas_queue.set_items(items_snapshot)
        self.canvas_queue.set_selected_ids(self.selected_queue_ids)
        self.update_settings_header_label()
        self.update_settings_summary()
        self._update_queue_stats()
        if removed_count > 0: self.append_log(f"[INFO] Cleared {removed_count} queued item(s).\n")

    def _update_queue_stats(self):
        with self.queue_lock:
            total = len(self.queue_items)
            completed = sum(1 for q in self.queue_items if q["status"] in ("completed", "failed", "cancelled"))
            running = sum(1 for q in self.queue_items if q["status"] == "encoding")
            on_hold = sum(1 for q in self.queue_items if q["status"] == "suspended")
            queued = sum(1 for q in self.queue_items if q["status"] == "queued")
            total_progress = 0.0
            for q in self.queue_items:
                st = q.get("status")
                if st in ("completed", "failed", "cancelled"):
                    total_progress += 1.0
                elif st in ("encoding", "suspended"):
                    item_pct = float(self.last_pct_map.get(q["id"], 0.0))
                    total_progress += min(0.999, max(0.0, item_pct / 100.0))

        if total == 0:
            self.lbl_batch_status.configure(text="Queue is empty")
            self.lbl_batch_pct.configure(text="0%")
            self.batch_progress_bar.set(0)
        else:
            pct = min(1.0, max(0.0, total_progress / total)) if total > 0 else 0.0
            self.batch_progress_bar.set(pct)
            self.lbl_batch_pct.configure(text=f"{int(pct * 100)}%")
            txt = f"Batch: {completed}/{total} Completed"
            parts = []
            if running > 0: parts.append(f"{running} Active")
            if on_hold > 0: parts.append(f"{on_hold} On Hold")
            if queued > 0: parts.append(f"{queued} Queued")
            if parts: txt += " • " + " • ".join(parts)
            self.lbl_batch_status.configure(text=txt)

    def add_files_dialog(self):
        ext_patterns = " ".join(f"*{ext}" for ext in SUPPORTED_EXTENSIONS)
        files = filedialog.askopenfilenames(title="Select Video Files", filetypes=[("Supported Videos", ext_patterns), ("All Files", "*.*")])
        if files: self.handle_incoming_files(files)

    def add_folder_dialog(self):
        folder = filedialog.askdirectory(title="Select Folder to Encode")
        if folder: self.handle_incoming_files([folder])

    def handle_action_button(self):
        if not self.is_running:
            self.start_batch()
        else:
            self.toggle_pause()

    def update_action_button_ui(self):
        if not hasattr(self, "btn_pause"):
            return
        if not self.is_running:
            self.btn_pause.configure(
                text="▶  Start",
                fg_color=ULTRA_BG,
                hover_color=ULTRA_BG_HOVER,
                text_color=ULTRA_TEXT,
                border_width=1,
                border_color=ULTRA_BORDER,
                state="normal"
            )
        elif self.is_paused:
            self.btn_pause.configure(
                text="▶  Resume",
                fg_color=HOLD_BG,
                hover_color=HOLD_BG_HOVER,
                text_color=HOLD_TEXT,
                border_width=1,
                border_color=HOLD_BORDER,
                state="normal"
            )
        else:
            self.btn_pause.configure(
                text="⏸  Pause",
                fg_color=NEUTRAL_BTN,
                hover_color=NEUTRAL_BTN_HOVER,
                text_color=TEXT_PRIMARY,
                border_width=0,
                state="normal"
            )

    def start_batch(self):
        if self.is_running:
            return
        self.clear_selection()
        self._dispatcher_crash_count = 0
        with self.queue_lock:
            has_queued = any(q["status"] == "queued" for q in self.queue_items)
            if not has_queued:
                self.append_log("[INFO] No queued items to encode.\n")
                return
            if not self.dispatcher_alive:
                self.dispatcher_alive = True
                self.is_running = True
                self.is_paused = False
                self.set_app_state("encoding")
                threading.Thread(target=self._batch_dispatcher, daemon=True).start()

    def on_queue_item_selected(self, item_id, event=None):
        if item_id is None:
            self.clear_selection()
            return
        with self.queue_lock:
            item = self.items_by_id.get(item_id)
            if not item or item.get("status") != "queued":
                self.clear_selection()
                return

        state = getattr(event, "state", 0) if event else 0
        if not isinstance(state, int):
            state = 0

        is_shift = bool(state & 0x0001)
        is_cmd_or_ctrl = bool(state & 0x0004 or state & 0x0008 or state & 0x0010 or state & 0x0018)

        if is_shift:
            pivot_id = getattr(self, "_selection_pivot_id", None)
            with self.queue_lock:
                all_ids = [q["id"] for q in self.queue_items]
            if pivot_id in all_ids and item_id in all_ids:
                idx1 = all_ids.index(pivot_id)
                idx2 = all_ids.index(item_id)
                low, high = min(idx1, idx2), max(idx1, idx2)
                with self.queue_lock:
                    range_ids = {
                        q["id"] for q in self.queue_items[low:high + 1]
                        if q.get("status") == "queued"
                    }
                if is_cmd_or_ctrl:
                    self.selected_queue_ids.update(range_ids)
                else:
                    self.selected_queue_ids = range_ids
            else:
                self.selected_queue_ids = {item_id}
                self._selection_pivot_id = item_id
        elif is_cmd_or_ctrl:
            if item_id in self.selected_queue_ids:
                self.selected_queue_ids.remove(item_id)
                if getattr(self, "_selection_pivot_id", None) == item_id:
                    self._selection_pivot_id = next(iter(self.selected_queue_ids)) if self.selected_queue_ids else None
            else:
                self.selected_queue_ids.add(item_id)
                self._selection_pivot_id = item_id
        else:
            if self.selected_queue_ids == {item_id}:
                self.selected_queue_ids.clear()
                self._selection_pivot_id = None
            else:
                self.selected_queue_ids = {item_id}
                self._selection_pivot_id = item_id

        self.canvas_queue.set_selected_ids(self.selected_queue_ids)
        self.load_selected_item_settings()

    def load_selected_item_settings(self):
        if not self.selected_queue_ids:
            self.update_settings_header_label()
            self.update_settings_summary()
            return
        # If 1 item is selected, load its values. If multiple items are selected,
        # load the pivot/clicked item's settings so user can use them as a base to override.
        target_id = getattr(self, "_selection_pivot_id", None)
        if not target_id or target_id not in self.selected_queue_ids:
            target_id = next(iter(self.selected_queue_ids))
        with self.queue_lock:
            item = self.items_by_id.get(target_id)
            st = dict(item.get("settings", {})) if item else None
        if st:
            self._loading_selection_settings = True
            try:
                c_val = st.get("codec", "HEVC (H.265)")
                self.codec_var.set(c_val)
                e_val = st.get("encoder", "AppleMediaEngine")
                self.current_encoder = e_val
                e_val = st.get("encoder", "AppleMediaEngine")
                self.encoder_var.set(e_val)
                self.sync_encoder_ui()

                chr_val = st.get("chroma", DEFAULT_CHROMA)
                if not HAS_VT_422 and "4:2:2" in chr_val:
                    chr_val = "10-Bit 4:2:0"
                self.chroma_var.set(chr_val)

                q_val = int(st.get("quality", 69))
                q_enc = st.get("quality_encoder", e_val)
                if e_val == "AppleMediaEngine":
                    if q_enc == "CPU" and q_val <= 51:
                        q_val = max(1, min(100, int(round((q_val / 51.0) * 100))))
                    self.last_vt_quality = q_val
                else:
                    if q_enc == "AppleMediaEngine" or q_val > 51:
                        q_val = max(0, min(51, int(round((q_val / 100.0) * 51))))
                    self.last_cpu_crf = q_val
                self.quality_slider.set(q_val)
                self.lbl_quality_val.configure(text=get_quality_description(q_val, e_val))

                d_raw = float(st.get("denoise", 10))
                d_val = int(round(d_raw * 1000)) if 0.0 < d_raw < 1.0 else int(round(d_raw))
                self.denoise_slider.set(d_val)
                self.lbl_denoise_val.configure(text=get_denoise_description(d_val))

                if "dest_dir" in st and st["dest_dir"]:
                    self.dest_var.set(st["dest_dir"])
                if "tag_settings" in st and hasattr(self, "cb_tag_settings"):
                    self.tag_settings = bool(st["tag_settings"])
                    if self.tag_settings: self.cb_tag_settings.select()
                    else: self.cb_tag_settings.deselect()
            finally:
                self._loading_selection_settings = False
        self.update_settings_header_label()
        self.update_settings_summary()

    def clear_selection(self):
        if getattr(self, "selected_queue_ids", None):
            self.selected_queue_ids.clear()
            self._selection_pivot_id = None
            self.canvas_queue.set_selected_ids(self.selected_queue_ids)
            self.update_settings_header_label()
            self.update_settings_summary()

    def _on_delete_key(self, event=None):
        try:
            focused = self.root.focus_get()
            if focused:
                w_class = focused.winfo_class()
                if w_class in ("Entry", "Text", "TEntry", "TCombobox"):
                    return
        except Exception:
            pass
        if getattr(self, "selected_queue_ids", None):
            self.delete_selected_queue_items()
            return "break"

    def delete_selected_queue_items(self):
        sel = list(getattr(self, "selected_queue_ids", set()))
        if not sel:
            return
        removed_count = 0
        to_cancel = []
        with self.queue_lock:
            for iid in sel:
                item = self.items_by_id.get(iid)
                if not item:
                    continue
                if item.get("status") == "queued":
                    if item in self.queue_items:
                        self.queue_items.remove(item)
                    self.items_by_id.pop(iid, None)
                    removed_count += 1
                else:
                    to_cancel.append(iid)
            self.selected_queue_ids.clear()
            self._selection_pivot_id = None
            items_snapshot = list(self.queue_items)

        for cid in to_cancel:
            self.cancel_single_item(cid)

        self.canvas_queue.set_items(items_snapshot)
        self.canvas_queue.set_selected_ids(self.selected_queue_ids)
        self.update_settings_header_label()
        self.update_settings_summary()
        self._update_queue_stats()
        if removed_count > 0:
            self.append_log(f"[INFO] Removed {removed_count} selected item(s) from queue.\n")

    def apply_settings_to_selected(self):
        if getattr(self, "_loading_selection_settings", False):
            return
        if not getattr(self, "selected_queue_ids", None):
            return
        current_settings = self.get_current_settings()
        with self.queue_lock:
            for iid in list(self.selected_queue_ids):
                item = self.items_by_id.get(iid)
                if item and item.get("status") == "queued":
                    item["settings"] = dict(current_settings)
            items_snapshot = list(self.queue_items)
        self.canvas_queue.set_items(items_snapshot)
        self.canvas_queue.set_selected_ids(self.selected_queue_ids)

    def toggle_pause(self):
        if not self.is_running: return
        with self.process_lock:
            try:
                if not self.is_paused:
                    self.is_paused = True
                    self.set_app_state("paused")
                    for proc in list(self.active_processes.values()):
                        if proc and proc.poll() is None:
                            safe_killpg(proc, signal.SIGSTOP)
                    self.append_log("❚❚ [PAUSED] Encoding queue paused.\n")
                else:
                    self.is_paused = False
                    self.set_app_state("encoding")
                    for item_id in list(self.running_ids):
                        proc = self.active_processes.get(item_id)
                        if proc and proc.poll() is None:
                            safe_killpg(proc, signal.SIGCONT)
                    self.append_log("▶ [RESUMED] Encoding queue resumed.\n")
            except Exception as e: self.append_log(f"[ERROR] Pause toggle failed: {e}\n")

    def cancel_current(self):
        with self.process_lock: has_active = bool(self.running_ids or self.active_processes)
        if not has_active or not self.is_running: return
        if messagebox.askyesno("Cancel Encodings", "Stop currently active encodes in this window?"):
            def terminate_active():
                procs_to_wait = []
                with self.process_lock:
                    active_ids = list(self.running_ids | set(self.active_processes.keys()))
                    self._last_hw_release_time = time.time()
                    for item_id in active_ids:
                        self.cancelled_ids.add(item_id)
                        self.suspended_ids.discard(item_id)
                        self.running_ids.discard(item_id)
                        proc = self.active_processes.get(item_id)
                        if proc and proc.poll() is None:
                            safe_killpg(proc, signal.SIGCONT, signal.SIGKILL)
                            procs_to_wait.append(proc)
                for proc in procs_to_wait:
                    try:
                        proc.wait(timeout=0.5)
                    except Exception:
                        pass
            threading.Thread(target=terminate_active, daemon=True).start()

    def probe_media_file(self, filepath, timeout=20):
        cmd = [
            FFPROBE_BIN, "-v", "error",
            "-show_format", "-show_streams", "-show_chapters",
            "-of", "json", filepath
        ]
        for attempt in range(2):
            try:
                to = timeout if attempt == 0 else max(timeout, 25)
                res = subprocess.run(cmd, capture_output=True, text=True, timeout=to)
                if res.returncode == 0 and res.stdout.strip():
                    return json.loads(res.stdout)
            except Exception:
                pass
        return {}

    def get_probe_data(self, item_or_path):
        if isinstance(item_or_path, dict):
            cached = item_or_path.get("probe_data")
            if cached and cached.get("streams"):
                return cached
            probe = self.probe_media_file(item_or_path["path"])
            if probe and probe.get("streams"):
                item_or_path["probe_data"] = probe
            return probe
        return self.probe_media_file(item_or_path)

    def get_video_stream_info(self, filepath, probe_data=None):
        duration, fps, width, height, timecode, pix_fmt = 0.0, 30.0, 0, 0, None, ""
        data = probe_data if (probe_data and probe_data.get("streams")) else self.probe_media_file(filepath)
        fdata = data.get("format", {})
        if "duration" in fdata:
            try: duration = max(0.0, float(fdata["duration"]))
            except ValueError: pass
        ftags = {str(k).lower(): v for k, v in fdata.get("tags", {}).items()}
        if "timecode" in ftags: timecode = ftags["timecode"]

        streams = data.get("streams", [])
        v_stream = next((s for s in streams if s.get("codec_type") == "video" and (s.get("disposition", {}) or {}).get("attached_pic") != 1), None)
        if not v_stream:
            v_stream = next((s for s in streams if s.get("codec_type") == "video"), None)
        if v_stream:
            if "duration" in v_stream:
                try: duration = max(duration, float(v_stream["duration"]))
                except ValueError: pass
        for s in streams:
            if "duration" in s:
                try: duration = max(duration, float(s["duration"]))
                except ValueError: pass
            if "width" in v_stream:
                try: width = int(v_stream["width"])
                except ValueError: pass
            if "height" in v_stream:
                try: height = int(v_stream["height"])
                except ValueError: pass
            stags = {str(k).lower(): v for k, v in v_stream.get("tags", {}).items()}
            if not timecode and "timecode" in stags: timecode = stags["timecode"]
            if "pix_fmt" in v_stream: pix_fmt = str(v_stream["pix_fmt"]).lower()

            def parse_rate(rate_str):
                if not rate_str or rate_str in ("0/0", "N/A"): return None
                try:
                    if "/" in rate_str:
                        n, d = rate_str.split("/", 1)
                        return (float(n) / float(d)) if float(d) > 0 else None
                    return float(rate_str)
                except: return None

            fps_cand = parse_rate(v_stream.get("avg_frame_rate")) or parse_rate(v_stream.get("r_frame_rate"))
            if fps_cand and 1.0 <= fps_cand <= 300.0: fps = fps_cand
        return duration, fps, width, height, timecode, pix_fmt

    def get_audio_args(self, filepath, probe_data=None):
        data = probe_data if (probe_data and probe_data.get("streams")) else self.probe_media_file(filepath)
        streams = [s for s in data.get("streams", []) if s.get("codec_type") == "audio"]
        args = []
        out_a_idx = 0
        for s in streams:
            s_idx = s.get("index")
            if s_idx is None:
                continue
            codec = s.get("codec_name", "").lower()
            try: ch = int(s.get("channels") or 2)
            except: ch = 2
            br = "512k" if ch >= 8 else ("448k" if ch >= 6 else ("256k" if ch >= 4 else ("192k" if ch >= 2 else "128k")))
            st_raw = s.get("start_time") or data.get("format", {}).get("start_time")
            is_zero_start = True if st_raw is None else False
            if st_raw is not None and str(st_raw).strip() not in ("", "N/A"):
                try:
                    # Allow up to ~85ms of standard audio priming delay
                    is_zero_start = (abs(float(st_raw)) < 0.085)
                except (ValueError, TypeError):
                    is_zero_start = False
            args.extend(["-map", f"0:{s_idx}"])
            if codec == "aac" and is_zero_start:
                args.extend([f"-c:a:{out_a_idx}", "copy"])
            elif ch > 8:
                args.extend([f"-c:a:{out_a_idx}", "aac", f"-ac:a:{out_a_idx}", "2", f"-b:a:{out_a_idx}", "256k"])
            else:
                args.extend([f"-c:a:{out_a_idx}", "aac", f"-b:a:{out_a_idx}", br])
            stags = s.get("tags", {}) or {}
            if "language" in stags:
                args.extend([f"-metadata:s:a:{out_a_idx}", f"language={stags['language']}"])
            if "title" in stags:
                args.extend([f"-metadata:s:a:{out_a_idx}", f"title={stags['title']}"])
            out_a_idx += 1
        if not args:
            args = ["-map", "0:a?", "-c:a", "copy"]
        return args

    def get_subtitle_args(self, filepath, probe_data=None):
        data = probe_data if probe_data is not None else self.probe_media_file(filepath)
        streams = [s for s in data.get("streams", []) if s.get("codec_type") == "subtitle"]
        args = []
        sub_out_idx = 0
        for s in streams:
            codec = s.get("codec_name", "").lower()
            s_idx = s.get("index")
            tags = s.get("tags", {}) or {}
            handler = str(tags.get("handler_name", "")).lower()
            if any(k in handler for k in ("telemetry", "gps", "data", "gpmd", "djmd")): continue
            if codec in ("mov_text", "subrip", "srt", "text", "webvtt") and s_idx is not None:
                args.extend(["-map", f"0:{s_idx}", f"-c:s:{sub_out_idx}", "mov_text", "-strict", "-2", f"-metadata:s:s:{sub_out_idx}", "handler_name=Subtitle"])
                sub_out_idx += 1
            elif codec in ("ass", "ssa", "hdmv_pgs_subtitle"):
                self.append_log(f"ℹ️ [INFO] Stylized/bitmap subtitle stream #{s_idx} ({codec}) dropped (incompatible with MP4 container).\n")
        return args

    def get_color_and_hdr_metadata(self, filepath, probe_data=None):
        range_ff, range_x265, c_space, c_prim, c_trc, master_display_str, cll_str = "tv", "limited", None, None, None, None, None
        data = probe_data if probe_data is not None else self.probe_media_file(filepath)
        streams = data.get("streams", [])
        v_stream = next((s for s in streams if s.get("codec_type") == "video" and (s.get("disposition", {}) or {}).get("attached_pic") != 1), None)
        if not v_stream:
            v_stream = next((s for s in streams if s.get("codec_type") == "video"), None)
        if v_stream:
            raw_range = v_stream.get("color_range", "")
            range_ff, range_x265 = ("full", "full") if raw_range in ["pc", "full", "jpeg"] else ("tv", "limited")

            def sanitize_col(val):
                return None if (not val or str(val).strip().lower() in ("unknown", "unspecified", "reserved")) else str(val).strip()

            c_space = sanitize_col(v_stream.get("color_space"))
            if c_space in ("bt2020_ncl", "bt2020"): c_space = "bt2020nc"
            c_prim = sanitize_col(v_stream.get("color_primaries"))
            c_trc = sanitize_col(v_stream.get("color_transfer"))

            side_data_list = list(v_stream.get("side_data_list", []))

            for sd in side_data_list:
                sd_type = sd.get("side_data_type", "")
                if "Mastering display" in sd_type and not master_display_str:
                    def parse_coord(k):
                        val = sd.get(k)
                        if val is None: return None
                        val_str = str(val).strip()
                        try:
                            f_val = float(val_str.split("/")[0]) / float(val_str.split("/")[1]) if "/" in val_str else float(val_str)
                            return int(round(f_val)) if f_val > 1.0 else int(round(f_val * 50000))
                        except: return None

                    def parse_lum(k, mult=10000):
                        val = sd.get(k)
                        if val is None: return None
                        val_str = str(val).strip()
                        try:
                            f_val = float(val_str.split("/")[0]) / float(val_str.split("/")[1]) if "/" in val_str else float(val_str)
                            return int(round(f_val)) if f_val >= 100000 else int(round(f_val * mult))
                        except: return None

                    try:
                        rx, ry = parse_coord("red_x"), parse_coord("red_y")
                        gx, gy = parse_coord("green_x"), parse_coord("green_y")
                        bx, by = parse_coord("blue_x"), parse_coord("blue_y")
                        wpx, wpy = parse_coord("white_point_x"), parse_coord("white_point_y")
                        min_l, max_l = parse_lum("min_luminance"), parse_lum("max_luminance")
                        if all(v is not None for v in [gx, gy, bx, by, rx, ry, wpx, wpy, max_l, min_l]):
                            master_display_str = f"G({gx},{gy})B({bx},{by})R({rx},{ry})WP({wpx},{wpy})L({max_l},{min_l})"
                    except Exception: pass
                elif "Content light level" in sd_type and not cll_str:
                    try:
                        max_cll = int(float(sd.get("max_content") or 0))
                        max_fall = int(float(sd.get("max_average") or 0))
                        if max_cll > 0 or max_fall > 0: cll_str = f"{max_cll},{max_fall}"
                    except Exception: pass
        return range_ff, range_x265, c_space, c_prim, c_trc, master_display_str, cll_str

    def get_item_res_weight(self, item):
        if not item:
            return 1, False
        if "res_weight" in item:
            return item["res_weight"], item.get("is_8k", False)
        try:
            probe = self.get_probe_data(item)
            v_info = self.get_video_stream_info(item["path"], probe_data=probe)
            item["video_info"] = v_info
            _, _, w, h, _, _ = v_info
            w, h = (w or 0), (h or 0)
            pixels = w * h
            is_8k = (pixels >= 25_000_000) or (w >= 7000) or (h >= 4000)
            is_4k = (pixels >= 7_000_000) or (w >= 3500) or (h >= 2000)
            is_1440p = (pixels >= 3_000_000) or (w >= 2400) or (h >= 1300)
            if is_8k:
                weight = 6
            elif is_4k:
                weight = 2
            elif is_1440p:
                weight = 1
            else:
                weight = 1
            item["res_weight"] = weight
            item["is_8k"] = is_8k
            return weight, is_8k
        except Exception:
            item["res_weight"] = 1
            item["is_8k"] = False
            return 1, False

    def _batch_dispatcher(self):
        caffeinate_proc = None
        if shutil.which("caffeinate"):
            try: caffeinate_proc = subprocess.Popen(["caffeinate", "-dis", "-w", str(os.getpid())])
            except Exception: pass
        try:
            while True:
                if self.is_paused:
                    time.sleep(0.3)
                    continue

                # Settle hardware media engine after cancellation / kill events
                hw_cooldown = max(0.0, 1.0 - (time.time() - getattr(self, "_last_hw_release_time", 0.0)))
                if hw_cooldown > 0:
                    time.sleep(min(0.1, hw_cooldown))
                    continue

                # Hold off dispatching new encodes while any job is retrying
                if self.retrying_ids:
                    time.sleep(0.3)
                    continue

                active_enc = None
                with self.process_lock:
                    running_snapshot = list(self.running_ids)
                with self.queue_lock:
                    for rid in running_snapshot:
                        it = self.items_by_id.get(rid)
                        if it and it.get("settings", {}).get("encoder") == "CPU":
                            active_enc = "CPU"
                            break
                    if not active_enc:
                        for q in self.queue_items:
                            if q["status"] == "queued":
                                active_enc = q.get("settings", {}).get("encoder")
                                break

                budget = self.get_concurrency_budget(encoder=active_enc)
                max_units = budget["max_units"]
                max_8k = budget["max_8k"]
                max_jobs = budget["max_jobs"]

                with self.process_lock:
                    current_units, current_8k = self.rebalance_concurrency()

                # 3. Launch next queued jobs if resolution budget permits (hold if any job is retrying)
                now_t = time.time()
                stagger = 0.8 if current_8k > 0 else 0.2
                can_launch = (len(self.running_ids) < max_jobs) and (current_units < max_units or current_units == 0)
                if can_launch and not self.retrying_ids and not self.suspended_ids and (now_t - getattr(self, "_last_launch_time", 0.0)) >= stagger:
                    # Pre-probe queued candidates outside locks so ffprobe doesn't freeze the GUI
                    probe_count = 0
                    while probe_count < 5:
                        cand_probe = None
                        with self.queue_lock:
                            for q in self.queue_items:
                                if q["status"] == "queued" and "res_weight" not in q:
                                    cand_probe = q
                                    break
                        if not cand_probe:
                            break
                        self.get_item_res_weight(cand_probe)
                        probe_count += 1
                        w, is8 = cand_probe.get("res_weight", 1), cand_probe.get("is_8k", False)
                        fits = (current_units == 0) or (
                            (current_units + w <= max_units) and
                            (current_8k + (1 if is8 else 0) <= max_8k) and
                            (len(self.running_ids) < max_jobs)
                        )
                        if fits:
                            break

                    with self.process_lock:
                        with self.queue_lock:
                            next_cand = None
                            for q in self.queue_items:
                                if q["status"] == "queued":
                                    if "res_weight" not in q:
                                        break
                                    w, is8 = q["res_weight"], q.get("is_8k", False)
                                    fits = (current_units == 0) or (
                                        (current_units + w <= max_units) and
                                        (current_8k + (1 if is8 else 0) <= max_8k) and
                                        (len(self.running_ids) < max_jobs)
                                    )
                                    if fits:
                                        next_cand = q
                                        cand_w, cand_is8 = w, is8
                                        break
                            if next_cand:
                                next_cand["status"] = "encoding"
                                item_id = next_cand["id"]
                                current_units += cand_w
                                if cand_is8:
                                    current_8k += 1

                        if next_cand:
                            self.running_ids.add(item_id)
                            self._last_launch_time = time.time()
                            self.worker_threads = [t for t in self.worker_threads if t.is_alive()]
                            t = threading.Thread(target=self._encode_single_file, args=(next_cand,), daemon=True)
                            self.worker_threads.append(t)
                            t.start()

                with self.process_lock:
                    with self.queue_lock:
                        has_unfinished = any(q["status"] in ("queued", "encoding") for q in self.queue_items)
                        has_active = bool(self.active_processes) or bool(self.running_ids) or bool(self.suspended_ids)
                        is_scanning = getattr(self, "active_scans", 0) > 0
                        if not has_unfinished and not has_active and not is_scanning:
                            if not any(q["status"] == "queued" for q in self.queue_items):
                                rotate_log_file()
                                if os.path.exists(SOUND_CHIME):
                                    try: subprocess.Popen(["afplay", SOUND_CHIME])
                                    except Exception: pass
                                self.is_running = False
                                self.dispatcher_alive = False
                                break
                time.sleep(0.1)
        except Exception:
            self._dispatcher_crash_count = getattr(self, "_dispatcher_crash_count", 0) + 1
            self.append_log(f"✖ [DISPATCHER CRASH ({self._dispatcher_crash_count}/3)] {traceback.format_exc()}\n")
        finally:
            if caffeinate_proc and caffeinate_proc.poll() is None:
                try: caffeinate_proc.terminate()
                except Exception: pass
            respawn_needed = False
            respawn_delay = 0.0
            with self.process_lock:
                with self.queue_lock:
                    is_scanning = getattr(self, "active_scans", 0) > 0
                    has_queued = any(q["status"] == "queued" for q in self.queue_items)
                    crashes = getattr(self, "_dispatcher_crash_count", 0)
                    auto_start = getattr(self, "auto_start", False)
                    should_respawn = not self.cancel_requested and (
                        (has_queued and auto_start) or
                        (is_scanning and auto_start) or
                        (crashes > 0 and (has_queued or is_scanning))
                    )
                    if crashes >= 3:
                        self.is_running = False
                        self.dispatcher_alive = False
                        self.cancel_requested = False
                        self.set_app_state("idle")
                        self.ui_queue.put(("refresh_stats", None))
                        self.append_log("🛑 [DISPATCHER HALTED] Dispatcher stopped after 3 consecutive crashes. Please check logs or settings.\n")
                        self.root.after(0, lambda: messagebox.showerror("Dispatcher Error", "Dispatcher halted after 3 consecutive crashes.\nCheck the Live Console for details."))
                    elif should_respawn:
                        if crashes > 0:
                            respawn_delay = 1.0
                        self.is_running = True
                        self.dispatcher_alive = True
                        self.set_app_state("encoding")
                        respawn_needed = True
                    else:
                        self.is_running = False
                        self.dispatcher_alive = False
                        self.cancel_requested = False
                        self.set_app_state("idle")
                        self.ui_queue.put(("refresh_stats", None))
            if respawn_needed:
                if respawn_delay > 0:
                    time.sleep(respawn_delay)
                threading.Thread(target=self._batch_dispatcher, daemon=True).start()

    def _encode_single_file(self, current_item):
        f = current_item["path"]
        item_id = current_item["id"]
        base_name = current_item["filename"]
        display_name = current_item.get("display_name", base_name)
        rel_dir = current_item.get("rel_dir", "")
        proc, lock_file, out_file = None, None, None
        exit_code = 1
        is_cancelled = False

        try:
            with self.process_lock:
                if item_id in self.cancelled_ids or self.cancel_requested:
                    with self.queue_lock: current_item["status"] = "cancelled"
                    self.update_item_status_ui(item_id, "cancelled", refresh_stats=True)
                    return

            settings = current_item.get("settings", {})
            dest_dir = settings.get("dest_dir", os.path.expanduser("~/Desktop"))
            codec_choice = settings.get("codec", "HEVC (H.265)")
            is_h264 = ("H.264" in codec_choice)
            encoder_choice = settings.get("encoder", "AppleMediaEngine")
            chroma_choice = settings.get("chroma", "10-Bit 4:2:2")
            denoise_raw = float(settings.get("denoise", 10))
            denoise_val = int(round(denoise_raw * 1000)) if 0.0 < denoise_raw < 1.0 else int(round(denoise_raw))
            q_val = settings.get("quality", 69)
            speed_preset = settings.get("speed", "fast")

            denoise_desc = get_denoise_description(denoise_val)
            is_videotoolbox = encoder_choice == "AppleMediaEngine"

            probe = self.get_probe_data(current_item)
            if not probe or not probe.get("streams"):
                self.append_log(f"⚠️ [WARNING] Metadata probe empty or timed out for '{display_name}'. Re-probing with extended timeout...\n")
                probe = self.probe_media_file(f, timeout=25)
                if probe and probe.get("streams"):
                    current_item["probe_data"] = probe
            if "video_info" in current_item and current_item["video_info"][2] > 0:
                duration, fps, width, height, timecode, pix_fmt_in = current_item["video_info"]
            else:
                duration, fps, width, height, timecode, pix_fmt_in = self.get_video_stream_info(f, probe_data=probe)
                current_item["video_info"] = (duration, fps, width, height, timecode, pix_fmt_in)
            has_alpha = any(a in pix_fmt_in for a in ("yuva", "rgba", "bgra", "argb", "abgr", "gbrpa", "gbrap", "ya8", "ya16"))

            if has_alpha and (not is_videotoolbox or is_h264):
                self.append_log(f"⚠️ [NOTICE] Alpha channel (transparency) detected in '{display_name}'. CPU / H.264 encoders do not support alpha transparency; automatically routing to AppleMediaEngine (hevc_videotoolbox) to preserve alpha.\n")
                is_videotoolbox = True
                is_h264 = False
                codec_choice = "HEVC (H.265)"
                encoder_choice = "AppleMediaEngine"
                q_val = getattr(self, "last_vt_quality", 69)

            saved_enc = settings.get("quality_encoder", settings.get("encoder", "AppleMediaEngine"))
            raw_q = int(settings.get("quality", 69 if is_videotoolbox else 33))

            if is_videotoolbox:
                if saved_enc == "CPU" and raw_q <= 51:
                    q_val = max(1, min(100, int(round((raw_q / 51.0) * 100))))
                else:
                    q_val = max(1, min(100, int(q_val)))
            elif encoder_choice == "CPU":
                if saved_enc == "AppleMediaEngine" or raw_q > 51:
                    cpu_slider_val = int(round((raw_q / 100.0) * 51))
                else:
                    cpu_slider_val = raw_q
                crf = max(0, min(51, 51 - cpu_slider_val))
                q_val = crf
            else:
                q_val = max(0, min(51, 51 - int(q_val)))

            if is_videotoolbox:
                if is_h264: codec_name, profile_str, pix_fmt_str = "h264_videotoolbox", "high", "nv12"
                else:
                    codec_name = "hevc_videotoolbox"
                    if has_alpha: profile_str, pix_fmt_str = None, "bgra"
                    elif "4:2:2" in chroma_choice: profile_str, pix_fmt_str = "main42210", "p210le"
                    elif "10-Bit" in chroma_choice: profile_str, pix_fmt_str = "main10", "p010le"
                    else: profile_str, pix_fmt_str = "main", "nv12"
            else:
                if is_h264:
                    codec_name = "libx264"
                    if has_alpha:
                        self.append_log(f"⚠️ [WARNING] libx264 cannot encode alpha channel for '{display_name}'. Alpha will be stripped to black.\n")
                    profile_str, pix_fmt_str = "high", "yuv420p"
                else:
                    codec_name = "libx265"
                    if has_alpha:
                        self.append_log(f"⚠️ [WARNING] libx265 cannot encode alpha channel for '{display_name}'. Alpha will be stripped to black.\n")
                    if "4:2:2" in chroma_choice: profile_str, pix_fmt_str = "main422-10", "yuv422p10le"
                    elif "10-Bit" in chroma_choice: profile_str, pix_fmt_str = "main10", "yuv420p10le"
                    else: profile_str, pix_fmt_str = "main", "yuv420p"

            out_ext = ".mov" if (has_alpha and not is_h264) else ".mp4"
            settings_tag = get_settings_filename_tag(settings) if settings.get("tag_settings", False) else ""
            out_file, lock_file = generate_safe_output_path(f, dest_dir, rel_dir=rel_dir, ext=out_ext, suffix=settings_tag)
            with self.process_lock:
                self.active_output_files[item_id] = (out_file, lock_file)

            gop_size = max(48, int(round(fps * 3)))
            min_keyint = max(1, int(round(fps)))
            audio_args = self.get_audio_args(f, probe_data=probe)
            if not audio_args:
                audio_args = ["-map", "0:a?", "-c:a", "copy"]
            subtitle_args = self.get_subtitle_args(f, probe_data=probe)

            range_ff, range_x265, color_space, color_prim, color_trc, master_display_str, cll_str = self.get_color_and_hdr_metadata(f, probe_data=probe)
            is_pq = color_trc in ("smpte2084", "pq")
            is_hlg = color_trc in ("arib-std-b67", "hlg", "arib_std_b67")
            is_bt2020 = color_prim in ("bt2020", "bt2020-10", "bt2020-12", "bt2020_10", "bt2020_12")
            wide_or_hdr = (is_pq or is_hlg) or is_bt2020 or bool(master_display_str or cll_str)

            is_sd = (width < 1280 and height < 720 and width > 0 and height > 0)
            default_matrix = "smpte170m" if is_sd else "bt709"
            default_num = 6 if is_sd else 1

            c_prim_num = PRIMARIES_MAP.get(str(color_prim).lower()) or (9 if wide_or_hdr else default_num)
            c_trc_num = TRANSFER_MAP.get(str(color_trc).lower()) or (16 if is_pq else (18 if is_hlg else default_num))
            c_matrix_num = MATRIX_MAP.get(str(color_space).lower()) or (9 if wide_or_hdr else default_num)
            ff_prim = FFMPEG_CANONICAL_PRIMARIES.get(str(color_prim).lower(), color_prim) if color_prim else ("bt2020" if wide_or_hdr else default_matrix)
            ff_trc = FFMPEG_CANONICAL_TRC.get(str(color_trc).lower(), color_trc) if color_trc else ("smpte2084" if is_pq else ("arib-std-b67" if is_hlg else default_matrix))
            ff_space = FFMPEG_CANONICAL_SPACE.get(str(color_space).lower(), color_space) if color_space else ("bt2020nc" if wide_or_hdr else default_matrix)
            range_num = 1 if range_ff == "full" else 0

            vf_filters = []
            if width % 2 != 0 or height % 2 != 0: vf_filters.insert(0, f"scale=trunc(iw/2)*2:trunc(ih/2)*2:flags=bicubic")

            denoise_log_info = denoise_desc
            if has_alpha:
                if denoise_val > 0:
                    denoise_desc = "Skipped (Alpha Channel)"
                fmt_tags = {str(k).lower(): str(v).lower() for k, v in probe.get("format", {}).get("tags", {}).items()}
                v_s0 = next((s for s in probe.get("streams", []) if s.get("codec_type") == "video"), {})
                v_tags = {str(k).lower(): str(v).lower() for k, v in v_s0.get("tags", {}).items()}
                alpha_mode_raw = (
                    fmt_tags.get("alpha_mode") or
                    v_tags.get("alpha_mode") or
                    fmt_tags.get("com.apple.quicktime.alpha_mode") or
                    v_tags.get("com.apple.quicktime.alpha_mode") or
                    str(v_s0.get("alpha_mode") or "")
                ).strip().lower()
                if not alpha_mode_raw:
                    for sd in v_s0.get("side_data_list", []):
                        if "alpha_mode" in sd:
                            alpha_mode_raw = str(sd["alpha_mode"]).strip().lower()
                            break
                is_premultiplied = any(p in alpha_mode_raw for p in ("premult", "pre-mult", "pre_mult")) or alpha_mode_raw == "2"
                if not is_premultiplied:
                    vf_filters.append("premultiply=inplace=1")
                else:
                    self.append_log(f"ℹ️ [INFO] Input '{display_name}' has premultiplied alpha (alpha_mode: {alpha_mode_raw}). Omitting premultiply filter.\n")
                vf_filters.append(f"format={pix_fmt_str}")
            elif denoise_val > 0 and (is_pq or is_hlg):
                hdr_type = "PQ" if is_pq else "HLG"
                denoise_desc = f"Skipped (HDR {hdr_type})"
                self.append_log(f"⚠️ [NOTICE] Denoising skipped for '{display_name}'. Temporal filtering in non-linear HDR ({hdr_type}) code space causes shadow crushing and highlight artifacts.\n")
                sp_parts = [f"range={range_ff}"]
                if ff_prim: sp_parts.append(f"color_primaries={ff_prim}")
                if ff_trc: sp_parts.append(f"color_trc={ff_trc}")
                if ff_space: sp_parts.append(f"colorspace={ff_space}")
                vf_filters.append(f"setparams={':'.join(sp_parts)}")
            elif denoise_val > 0:
                denoise_f = denoise_val / 1000.0
                th_y_a = min(0.30, max(0.005, round(denoise_f * 1.2, 4)))
                th_y_b = min(0.30, max(0.012, round(denoise_f * 3.5, 4)))
                th_c_a = min(0.30, max(0.010, round(denoise_f * 2.0, 4)))
                th_c_b = min(0.30, max(0.024, round(denoise_f * 5.5, 4)))
                s_frames = 9 if denoise_val >= 25 else (7 if denoise_val >= 15 else 5)
                planar_fmt = "yuv422p10le" if ("4:2:2" in chroma_choice and "10-Bit" in chroma_choice) else ("yuv420p10le" if "10-Bit" in chroma_choice else "yuv420p")

                vf_filters.extend([
                    f"format={planar_fmt}",
                    f"atadenoise=0a={th_y_a:.4f}:0b={th_y_b:.4f}:1a={th_c_a:.4f}:1b={th_c_b:.4f}:2a={th_c_a:.4f}:2b={th_c_b:.4f}:s={s_frames}:a=p",
                    f"format={pix_fmt_str}"
                ])
                sp_parts = [f"range={range_ff}"]
                if ff_prim: sp_parts.append(f"color_primaries={ff_prim}")
                if ff_trc: sp_parts.append(f"color_trc={ff_trc}")
                if ff_space: sp_parts.append(f"colorspace={ff_space}")
                vf_filters.append(f"setparams={':'.join(sp_parts)}")
                denoise_log_info = f"{denoise_desc} [{s_frames}f]"
            else:
                sp_parts = [f"range={range_ff}"]
                if ff_prim: sp_parts.append(f"color_primaries={ff_prim}")
                if ff_trc: sp_parts.append(f"color_trc={ff_trc}")
                if ff_space: sp_parts.append(f"colorspace={ff_space}")
                vf_filters.append(f"setparams={':'.join(sp_parts)}")

            hdr_tag = " [HDR]" if (is_pq or is_hlg or master_display_str) else ""
            cap_info = f"CQ:{q_val}" if is_videotoolbox else f"CRF:{q_val}"
            codec_tag = f"{codec_name}{hdr_tag}"
            current_item["codec_tag"] = codec_tag

            self.ui_queue.put(("job_start", (item_id, display_name, codec_tag)))
            self.update_item_status_ui(item_id, "encoding", "0%", refresh_stats=True)
            res_lbl = get_common_resolution_label(width, height).strip(" ()") or f"{width}x{height}"
            enc_name = "AppleMediaEngine" if is_videotoolbox else "CPU (Software)"
            self.append_log(
                f"\n▶ [START] {display_name}\n"
                f"  • Settings: {codec_choice} ({enc_name}) • {chroma_choice} • {cap_info} • Denoise: {denoise_desc}\n"
                f"  • Source:   {width}x{height} ({res_lbl}) @ {fps:.2f} fps • {format_time_duration(duration, duration >= 3600)}\n"
                f"  • Output:   {out_file}\n"
            )

            has_video = (width > 0 and height > 0)
            in_codec = ""
            in_profile = ""
            if is_videotoolbox and has_video:
                v_s = next((s for s in probe.get("streams", []) if s.get("codec_type") == "video"), {})
                in_codec = str(v_s.get("codec_name", "")).lower()
                in_profile = str(v_s.get("profile", "")).lower()

            is_10bit = any(x in pix_fmt_in for x in ("10le", "10be", "p010", "p210", "10")) or ("10" in in_profile)
            is_h264_input = in_codec in ("h264", "avc", "avc1")
            can_hwaccel_dec = (
                has_video and not wide_or_hdr and not has_alpha and (
                    ("hevc" in in_codec or "h265" in in_codec) or
                    ("prores" in in_codec) or
                    (is_h264_input and not is_10bit)
                )
            )

            cmd = [FFMPEG_BIN, "-hide_banner", "-nostdin", "-y", "-nostats", "-progress", "pipe:1"]
            if is_videotoolbox and can_hwaccel_dec:
                cmd.extend(["-hwaccel", "videotoolbox"])
            elif is_videotoolbox and wide_or_hdr and has_video:
                self.append_log(f"ℹ️ [INFO] HDR stream detected for '{display_name}'. Using software decoding to preserve HDR10 mastering display and light level side data.\n")
            elif is_videotoolbox and is_h264_input and is_10bit and has_video:
                self.append_log(f"ℹ️ [INFO] 10-Bit H.264 input detected for '{display_name}'. Using software decoding to prevent hardware decode corruption.\n")
            if is_videotoolbox:
                threads_per_proc = "4"
            else:
                total_cpus = os.cpu_count() or 8
                budget = self.get_concurrency_budget(encoder=encoder_choice)
                threads_per_proc = str(max(2, total_cpus // max(1, budget["max_jobs"])))
            v_map_args = ["-map", "0:V:0?"] if has_video else ["-vn"]
            cmd.extend([
                "-threads", threads_per_proc,
                "-i", f
            ] + v_map_args + [
                "-map", "-0:d?", "-map", "-0:t?",
                "-map_metadata", "0", "-ignore_unknown", "-avoid_negative_ts", "auto",
                "-threads", threads_per_proc
            ])
            cmd.extend(audio_args)
            cmd.extend(subtitle_args)

            if has_video:
                if timecode:
                    tc_str = str(timecode).strip()
                    if ";" in tc_str and not (29.9 < fps < 30.05 or 59.9 < fps < 60.05): tc_str = tc_str.replace(";", ":")
                    if re.match(r"^\d{2}:\d{2}:\d{2}[:;]\d{2}$", tc_str): cmd.extend(["-timecode", tc_str])

                cmd.extend(["-sws_flags", "bicubic+accurate_rnd"])
                if vf_filters: cmd.extend(["-vf", ",".join(vf_filters)])

                cmd.extend(["-c:v", codec_name])
                if profile_str: cmd.extend(["-profile:v", profile_str])
                cmd.extend(["-pix_fmt", pix_fmt_str])
                if not has_alpha and "4:2:2" not in chroma_choice: cmd.extend(["-chroma_sample_location", "topleft" if wide_or_hdr else "left"])
                if not (has_alpha and is_videotoolbox):
                    cmd.extend(["-color_range", range_ff])
                    if ff_space: cmd.extend(["-colorspace", ff_space])
                    if ff_prim: cmd.extend(["-color_primaries", ff_prim])
                    if ff_trc: cmd.extend(["-color_trc", ff_trc])

                v_tag = "avc1" if is_h264 else "hvc1"
                tag_args = ["-tag:v", v_tag, "-vtag", v_tag] if has_alpha else ["-tag:v", v_tag]
                movflags_str = "+faststart+use_metadata_tags" if has_alpha else "+faststart+use_metadata_tags+write_colr"
                if is_videotoolbox:
                    cmd.extend(["-allow_sw", "1"])
                    if has_alpha:
                        cmd.extend(["-alpha_quality", "0.75"])
                    is_8k = (width >= 7000 or height >= 4000)
                    vt_extra = ["-realtime", "1", "-prio_speed", "1"] if is_8k else (
                        (["-spatial_aq", "1"] if HAS_VT_SPATIAL_AQ else []) +
                        ["-prio_speed", "0", "-realtime", "0", "-power_efficient", "0"]
                    )
                    cmd.extend(["-q:v", str(q_val)] + vt_extra + ["-g", str(gop_size)] + tag_args + ["-movflags", movflags_str, "-strict", "experimental"])
                else:
                    c_prim_val = c_prim_num
                    c_trc_val = c_trc_num
                    c_matrix_val = c_matrix_num
                    if is_h264:
                        cmd.extend(["-crf", str(q_val), "-preset", speed_preset, "-g", str(gop_size), "-keyint_min", str(min_keyint), "-tag:v", v_tag, "-movflags", "+faststart+use_metadata_tags+write_colr", "-strict", "experimental"])
                    else:
                        x265_opts_list = ["sao=0", "aq-mode=3", "aq-strength=0.8", "rc-lookahead=25", "deblock=-1,-1", "psy-rd=1.5", "psy-rdoq=1.0", f"keyint={gop_size}", f"min-keyint={min_keyint}", f"range={range_x265}", "repeat-headers=1"]
                        x265_opts_list.append(f"pools={threads_per_proc}")
                        x265_opts_list.append(f"frame-threads={min(int(threads_per_proc), 4)}")
                        if c_prim_val: x265_opts_list.append(f"colorprim={c_prim_val}")
                        if c_trc_val: x265_opts_list.append(f"transfer={c_trc_val}")
                        if c_matrix_val is not None: x265_opts_list.append(f"colormatrix={c_matrix_val}")
                        if is_pq: x265_opts_list.extend(["hdr10-opt=1", "hdr10=1"])
                        if master_display_str: x265_opts_list.append(f"master-display={master_display_str}")
                        if cll_str: x265_opts_list.append(f"max-cll={cll_str}")
                        cmd.extend(["-crf", str(q_val), "-preset", speed_preset, "-g", str(gop_size), "-keyint_min", str(min_keyint), "-x265-params", ":".join(x265_opts_list), "-tag:v", v_tag, "-movflags", "+faststart+use_metadata_tags+write_colr", "-strict", "experimental"])
            else:
                cmd.extend(["-movflags", "+faststart+use_metadata_tags"])

            cmd.append(out_file)

            exit_code = 1
            stderr_dump = ""
            is_cancelled = False
            prefix = ["nice", "-n", "15"] if shutil.which("nice") else []

            for attempt in range(4):
                if attempt > 0:
                    self.last_pct_map[item_id] = 0.0
                    self.update_progress_ui(item_id, 0.0, "00:00 / --:--", "0.0x", "0 fps", "ETA: --:--")
                stderr_lines = deque(maxlen=1000)
                exec_cmd = prefix + cmd if prefix else cmd
                with self.hw_launch_lock:
                    with self.process_lock:
                        if item_id in self.cancelled_ids or self.cancel_requested:
                            self.retrying_ids.discard(item_id)
                            with self.queue_lock: current_item["status"] = "cancelled"
                            self.update_item_status_ui(item_id, "cancelled", refresh_stats=True)
                            return
                    now_l = time.time()
                    is_8k = (width >= 7000 or height >= 4000)
                    stagger_needed = (0.8 if is_8k else 0.2) if is_videotoolbox else 0.05
                    elapsed_launch = now_l - getattr(self, "_last_hw_launch_time", 0.0)
                    if elapsed_launch < stagger_needed:
                        time.sleep(stagger_needed - elapsed_launch)
                    proc = subprocess.Popen(exec_cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, errors="replace", bufsize=1, start_new_session=True)
                    self._last_hw_launch_time = time.time()
                    with self.process_lock:
                        self.retrying_ids.discard(item_id)
                with self.process_lock:
                    self.active_processes[item_id] = proc
                    if item_id in self.cancelled_ids or self.cancel_requested:
                        safe_killpg(proc, signal.SIGCONT, signal.SIGKILL)
                        try:
                            proc.wait(timeout=0.3)
                        except Exception: pass
                        with self.queue_lock: current_item["status"] = "cancelled"
                        self.update_item_status_ui(item_id, "cancelled", refresh_stats=True)
                        return
                    if item_id in self.suspended_ids or self.is_paused:
                        safe_killpg(proc, signal.SIGSTOP)

                last_heartbeat = [time.time()]
                first_frame_seen = [False]

                def capture_stderr(p):
                    try:
                        chunk, last_flush = [], time.time()
                        ignored_patterns = (
                            "non monotonically increasing dts", "dts < pts", "pts < dts",
                            "past duration", "last message repeated", "configuration:",
                            "built with", "libav", "input #", "output #", "stream mapping:",
                            "press [q] to stop", "x265 [info]:", "side data:", "frame=",
                            "fps=", "stream #", "metadata:", "encoder :", "duration:"
                        )
                        for eline in iter(p.stderr.readline, ''):
                            if eline:
                                last_heartbeat[0] = time.time()
                                stderr_lines.append(eline)
                                line_lower = eline.lower()
                                if any(noise in line_lower for noise in ignored_patterns):
                                    continue
                                if any(k in line_lower for k in ("error", "warning", "fatal", "failed", "unsupported")):
                                    clean_e = eline.strip()
                                    if clean_e:
                                        chunk.append(f"  [{display_name}] {clean_e}\n")
                                now = time.time()
                                if chunk and (len(chunk) >= 10 or (now - last_flush) >= 0.25):
                                    if not self.cancel_requested and item_id not in self.cancelled_ids:
                                        self.append_log("".join(chunk))
                                    chunk, last_flush = [], now
                        if chunk and not self.cancel_requested and item_id not in self.cancelled_ids:
                            self.append_log("".join(chunk))
                    except Exception: pass

                stderr_thread = threading.Thread(target=capture_stderr, args=(proc,), daemon=True)
                stderr_thread.start()

                def vt_watchdog(p):
                    while p and p.poll() is None:
                        time.sleep(1.5)
                        with self.process_lock:
                            is_held = self.is_paused or (item_id in self.suspended_ids)
                        if is_held:
                            last_heartbeat[0] = time.time()
                            continue
                        has_sw_filters = (denoise_val > 0 or any('atadenoise' in str(vf) for vf in vf_filters))
                        watchdog_timeout = (120.0 if has_sw_filters else 90.0) if first_frame_seen[0] else 180.0
                        if (time.time() - last_heartbeat[0]) > watchdog_timeout:
                            self.append_log(f"\n⚠️ [WATCHDOG] VideoToolbox stalled on {display_name}. Terminating hung ffmpeg process...\n")
                            with self.process_lock: self._last_hw_release_time = time.time()
                            safe_killpg(p, signal.SIGCONT, signal.SIGKILL)
                            try: p.wait(timeout=0.4)
                            except Exception: pass
                            break

                if is_videotoolbox and has_video:
                    watchdog_thread = threading.Thread(target=vt_watchdog, args=(proc,), daemon=True)
                    watchdog_thread.start()

                v_s0 = next((s for s in probe.get("streams", []) if s.get("codec_type") == "video" and (s.get("disposition", {}) or {}).get("attached_pic") != 1), None)
                total_frames = 0
                if v_s0:
                    try: total_frames = int(v_s0.get("nb_frames") or 0)
                    except (ValueError, TypeError): total_frames = 0
                if total_frames <= 0 and duration > 0 and fps > 0:
                    total_frames = int(round(duration * fps))

                cur_sec, raw_time_sec, cur_frame = 0.0, 0.0, 0
                max_cur_sec, max_pct = 0.0, 0.0
                speed, fps_display, last_progress_push = "1.0x", "0", 0.0
                for line in iter(proc.stdout.readline, ''):
                    if not line: break
                    first_frame_seen[0] = True
                    last_heartbeat[0] = time.time()
                    line = line.strip()
                    if "=" in line:
                        k, v = [x.strip() for x in line.split("=", 1)]
                        if k == "frame":
                            try: cur_frame = max(cur_frame, int(v))
                            except ValueError: pass
                        elif k == "out_time_us":
                            try: raw_time_sec = max(0.0, int(v) / 1_000_000.0)
                            except ValueError: pass
                        elif k == "out_time" and ":" in v:
                            try:
                                sign = -1.0 if v.startswith("-") else 1.0
                                p_list = v.lstrip("-+").split(":")
                                if len(p_list) == 3: raw_time_sec = max(0.0, sign * (float(p_list[0]) * 3600 + float(p_list[1]) * 60 + float(p_list[2])))
                            except ValueError: pass
                        elif k == "speed": speed = v if v and v != "N/A" else "0.0x"
                        elif k == "fps":
                            try: fps_display = f"{float(v):.0f}"
                            except ValueError: fps_display = v or "0"
                        elif k == "progress":
                            now_t = time.time()
                            if v == "end":
                                max_pct = 100.0
                                cur_sec = duration if duration > 0 else max_cur_sec
                                show_hours = (duration >= 3600) or (cur_sec >= 3600)
                                t_str = f"Time: {format_time_duration(cur_sec, show_hours)} / {format_time_duration(duration if duration > 0 else cur_sec, show_hours)}"
                                self.update_progress_ui(item_id, 100.0, t_str, f"Speed: {speed}", f"FPS: {fps_display}", "ETA: 00:00")
                                self.update_item_status_ui(item_id, "encoding", "100%")
                                break
                            else:
                                if (now_t - last_progress_push) >= 0.15:
                                    last_progress_push = now_t
                                    if has_video and total_frames > 0:
                                        raw_pct = min(99.9, max(0.0, (cur_frame / float(total_frames)) * 100.0))
                                        v_sec = (cur_frame / float(fps)) if fps > 0 else raw_time_sec
                                        cur_sec = max(max_cur_sec, v_sec if v_sec > 0 else raw_time_sec)
                                    else:
                                        cur_sec = max(max_cur_sec, raw_time_sec)
                                        raw_pct = min(99.9, max(0.0, (cur_sec / duration) * 100.0)) if duration > 0 else 0.0
                                    pct = max(max_pct, raw_pct)
                                    max_pct = pct
                                    max_cur_sec = cur_sec
                                    try: sp_val = float(speed.replace("x", "").strip())
                                    except ValueError: sp_val = 0.0
                                    eta_str = format_eta_str(max(0.0, (duration - cur_sec) / sp_val)) if (sp_val > 0 and cur_sec < duration) else "ETA: --:--"
                                    show_hours = (duration >= 3600) or (cur_sec >= 3600)
                                    t_str = f"Time: {format_time_duration(cur_sec, show_hours)} / {format_time_duration(duration, show_hours)}"
                                    with self.process_lock:
                                        is_suspended = (item_id in self.suspended_ids) or self.is_paused
                                    if not is_suspended:
                                        self.update_progress_ui(item_id, pct, t_str, f"Speed: {speed if 'x' in speed else speed + 'x'}", f"FPS: {fps_display}", eta_str)
                                        self.update_item_status_ui(item_id, "encoding", f"{int(pct)}%")

                proc.wait()
                stderr_thread.join(timeout=2.0)
                exit_code = proc.returncode
                stderr_dump = "".join(list(stderr_lines))
                is_cancelled = (self.cancel_requested or item_id in self.cancelled_ids)

                if exit_code != 0 and not is_cancelled and attempt < 3:
                    if "-timecode" in cmd and any(k in stderr_dump.lower() for k in ("timecode", "drop frame", "tmcd")):
                        self.append_log(f"⚠️ [WARNING] Timecode rejected for {display_name}. Retrying without timecode...\n")
                        if out_file and os.path.exists(out_file):
                            try: os.remove(out_file)
                            except OSError: pass
                        tc_idx = cmd.index("-timecode")
                        cmd.pop(tc_idx)
                        cmd.pop(tc_idx)
                        continue
                    if subtitle_args and any(arg in cmd for arg in subtitle_args) and any(k in stderr_dump.lower() for k in ("subtitle", "mov_text", "packet too large", "failed to convert", "subrip")):
                        self.append_log(f"⚠️ [WARNING] Subtitle muxing failed for {display_name}. Retrying without subtitles...\n")
                        if out_file and os.path.exists(out_file):
                            try: os.remove(out_file)
                            except OSError: pass
                        sub_len = len(subtitle_args)
                        for idx in range(len(cmd) - sub_len + 1):
                            if cmd[idx:idx + sub_len] == subtitle_args:
                                del cmd[idx:idx + sub_len]
                                break
                        subtitle_args = []
                        continue
                    if "-hwaccel" in cmd and any(k in stderr_dump.lower() for k in ("decode", "hwaccel", "vt hardware decode", "videotoolbox decoding")):
                        hw_idx = cmd.index("-hwaccel")
                        del cmd[hw_idx:hw_idx + 2]
                        self.append_log(f"⚠️ Retrying '{display_name}' using software decoding...\n")
                        if out_file and os.path.exists(out_file):
                            try: os.remove(out_file)
                            except OSError: pass
                        continue
                    is_hw_err = any(k in stderr_dump for k in ("-17691", "-12903", "-12905", "-12912", "-12915", "-542398533", "Error while opening encoder", "Error submitting video frame")) or exit_code in (187, -22, -9, -signal.SIGKILL)
                    if is_hw_err:
                        is_8k = (width >= 7000 or height >= 4000)
                        jitter = ((item_id * 37) % 9) * 0.4
                        base_backoff = 4.0 if is_8k else 2.5
                        backoff = base_backoff * (attempt + 1) + jitter
                        self.append_log(f"⚠️ [RETRY {attempt + 1}/3] Hardware media engine busy for {display_name}. Waiting {backoff:.1f}s to recover...\n")
                        if out_file and os.path.exists(out_file):
                            try: os.remove(out_file)
                            except OSError: pass
                        with self.process_lock:
                            self.retrying_ids.add(item_id)
                            self._last_hw_release_time = time.time()
                        self.update_item_status_ui(item_id, "encoding", f"RETRY {attempt + 1}")
                        sleep_end = time.time() + backoff
                        while time.time() < sleep_end:
                            if self.cancel_requested or item_id in self.cancelled_ids:
                                break
                            time.sleep(0.1)
                        continue
                break

            if exit_code == 0:
                self._dispatcher_crash_count = 0
                stats_str = ""
                try:
                    orig_sz = os.path.getsize(f) if (f and os.path.exists(f)) else 0
                    new_sz = os.path.getsize(out_file) if (out_file and os.path.exists(out_file)) else 0
                    final_dur = duration if duration > 0 else cur_sec
                    avg_bps = (new_sz * 8.0 / final_dur) if (final_dur > 0 and new_sz > 0) else 0
                    avg_br_str = format_bitrate(avg_bps)
                    new_sz_str = format_bytes(new_sz)
                    orig_sz_str = format_bytes(orig_sz)
                    if orig_sz > 0 and new_sz > 0:
                        diff_pct = ((orig_sz - new_sz) / float(orig_sz)) * 100.0
                        pval = round(abs(diff_pct), 1)
                        pnum = f"{int(pval)}%" if pval.is_integer() else f"{pval:.1f}%"
                        pct_str = f"-{pnum}" if diff_pct >= 0 else f"+{pnum}"
                    else:
                        pct_str = "0%"
                    stats_str = f"• {avg_br_str} • {new_sz_str} ({pct_str})"
                    self.append_log(f"✔ [COMPLETE] {display_name}  [{orig_sz_str} → {new_sz_str} ({pct_str}) • {avg_br_str}]\n")
                except Exception:
                    stats_str = ""
                    self.append_log(f"✔ [COMPLETE] {display_name}\n")
                with self.queue_lock:
                    current_item["status"] = "completed"
                    current_item["done_stats"] = stats_str
                with self.process_lock:
                    self.active_output_files.pop(item_id, None)
                self.update_item_status_ui(item_id, "completed", refresh_stats=True, done_stats=stats_str)
            else:
                if is_cancelled:
                    self.append_log(f"⚠ [CANCELLED] Skipped: {display_name}\n")
                    with self.queue_lock: current_item["status"] = "cancelled"
                    self.update_item_status_ui(item_id, "cancelled", refresh_stats=True)
                else:
                    err_hint = ""
                    if stderr_lines:
                        for el in reversed(list(stderr_lines)):
                            el_s = el.strip()
                            if el_s and any(w in el_s.lower() for w in ("error", "failed", "invalid", "fatal", "not supported", "cannot")):
                                err_hint = f"\n  Reason: {el_s}"
                                break
                    self.append_log(f"✖ [ERROR] Failed: {display_name} (Code {exit_code}){err_hint}\n")
                    with self.queue_lock: current_item["status"] = "failed"
                    self.update_item_status_ui(item_id, "failed", refresh_stats=True)
        except Exception:
            self.append_log(f"✖ [CRASH] {traceback.format_exc()}\n")
            with self.queue_lock: current_item["status"] = "failed"
            self.update_item_status_ui(item_id, "failed", refresh_stats=True)
        finally:
            is_completed = (exit_code == 0 and not is_cancelled)
            self.ui_queue.put(("job_end", (item_id, is_completed)))
            with self.process_lock:
                self.active_output_files.pop(item_id, None)
                self.retrying_ids.discard(item_id)
                if exit_code != 0 or is_cancelled:
                    self._last_hw_release_time = time.time()
                active_proc = self.active_processes.pop(item_id, None)
                self.running_ids.discard(item_id)
                self.suspended_ids.discard(item_id)
                self.cancelled_ids.discard(item_id)
                if active_proc and active_proc.poll() is None:
                    safe_killpg(active_proc, signal.SIGCONT, signal.SIGKILL)
                    try:
                        active_proc.wait(timeout=0.5)
                    except Exception: pass
            if current_item.get("status") != "completed" and out_file and os.path.exists(out_file):
                try:
                    os.remove(out_file)
                except OSError:
                    pass
            release_output_path(lock_file)
            self.rebalance_concurrency()

def main():
    def app_exit_handler():
        if _GLOBAL_APP_INSTANCE:
            try: _GLOBAL_APP_INSTANCE.kill_own_processes()
            except Exception: pass
        cleanup_system_ffmpeg()

    atexit.register(app_exit_handler)
    signal.signal(signal.SIGINT, lambda sig, frame: sys.exit(0))
    signal.signal(signal.SIGTERM, lambda sig, frame: sys.exit(0))
    if hasattr(signal, "SIGHUP"):
        signal.signal(signal.SIGHUP, lambda sig, frame: sys.exit(0))

    try:
        initial_files = [clean_file_path(f) for f in sys.argv[1:] if os.path.exists(clean_file_path(f)) and not f.startswith("-psn")]
        root = CTkWithDnD()
        app = EncoderApp(root, initial_files=initial_files)

        def on_mac_open(*args):
            found = []
            for arg in args:
                if isinstance(arg, (list, tuple)):
                    for item in arg:
                        c = clean_file_path(item)
                        if os.path.exists(c): found.append(c)
                elif isinstance(arg, str):
                    c = clean_file_path(arg)
                    if os.path.exists(c): found.append(c)
            if found:
                has_folder = any(os.path.isdir(x) for x in found)
                is_cold_start = (time.time() - getattr(app, "_startup_time", 0.0)) < 1.2
                should_inspect = (not is_cold_start) and (not has_folder) and (app.tabview.get() == "Media Inspector" or app.is_option_held())
                if should_inspect:
                    def _do_inspect():
                        app.tabview.set("Media Inspector")
                        app.inspect_file(found[0])
                    root.after(0, _do_inspect)
                else:
                    if has_folder and hasattr(app, "tabview"):
                        root.after(0, lambda: app.tabview.set("Batch Queue"))
                    root.after(0, lambda: app.handle_incoming_files(found))

        try: root.createcommand("::tk::mac::OpenDocument", on_mac_open)
        except Exception: pass
        root.mainloop()
    except Exception:
        with open(os.path.expanduser("~/Library/Logs/MediaEngine_crash.log"), "w") as f:
            f.write(traceback.format_exc())
        raise
    finally:
        cleanup_system_ffmpeg()

if __name__ == "__main__":
    main()
PYEOF

# 5. Convert PNG to Multi-Resolution Apple ICNS Format
PYINSTALLER_ICON_ARG=""
if [ -f "$ICON_SRC" ]; then
    echo "🎨 Processing icon from $ICON_SRC..."
    ICONSET_DIR="/tmp/AppIcon.iconset"
    ICNS_PATH="$WORKDIR/AppIcon.icns"
    rm -rf "$ICONSET_DIR" "$ICNS_PATH"
    mkdir -p "$ICONSET_DIR"

    sips -z 16 16     "$ICON_SRC" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null 2>&1
    sips -z 32 32     "$ICON_SRC" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null 2>&1
    sips -z 32 32     "$ICON_SRC" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null 2>&1
    sips -z 64 64     "$ICON_SRC" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null 2>&1
    sips -z 128 128   "$ICON_SRC" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null 2>&1
    sips -z 256 256   "$ICON_SRC" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null 2>&1
    sips -z 256 256   "$ICON_SRC" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null 2>&1
    sips -z 512 512   "$ICON_SRC" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null 2>&1
    sips -z 512 512   "$ICON_SRC" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null 2>&1
    sips -z 1024 1024 "$ICON_SRC" --out "$ICONSET_DIR/icon_512x512@2x.png" >/dev/null 2>&1

    iconutil -c icns "$ICONSET_DIR" -o "$ICNS_PATH"
    rm -rf "$ICONSET_DIR"

    if [ -f "$ICNS_PATH" ]; then
        PYINSTALLER_ICON_ARG="--icon=$ICNS_PATH"
        echo "✔ Generated standalone Apple ICNS icon"
    fi
fi

# 6. Build with PyInstaller
echo "🔨 Running PyInstaller..."
"$VENV_DIR/bin/pyinstaller" --windowed --noconfirm --clean \
    ${PYINSTALLER_ICON_ARG:+"$PYINSTALLER_ICON_ARG"} \
    --additional-hooks-dir=. \
    --collect-all customtkinter \
    --collect-all tkinterdnd2 \
    --collect-all tkinter \
    --osx-bundle-identifier "com.local.mediaengine" \
    --name "MediaEngine" \
    video_encoder_gui.py

# 7. Embed Standalone Static FFmpeg & FFprobe
echo "📦 Embedding static FFmpeg binaries into App bundle..."
BIN_DEST="dist/MediaEngine.app/Contents/MacOS"
mkdir -p "$BIN_DEST"

cp "$BIN_CACHE/ffmpeg" "$BIN_DEST/ffmpeg"
cp "$BIN_CACHE/ffprobe" "$BIN_DEST/ffprobe"
chmod +x "$BIN_DEST/ffmpeg" "$BIN_DEST/ffprobe"

# 8. Configure Info.plist
"$PYTHON_EXEC" - << 'PYPLIST'
import plistlib, os
plist_path = "dist/MediaEngine.app/Contents/Info.plist"
if os.path.exists(plist_path):
    with open(plist_path, "rb") as f:
        pl = plistlib.load(f)
    pl["CFBundleDocumentTypes"] = [{
        "CFBundleTypeName": "Media Files",
        "CFBundleRole": "Viewer",
        "LSHandlerRank": "Alternate",
        "LSItemContentTypes": ["public.movie", "public.video", "public.audio", "public.image", "public.folder", "public.directory"],
        "CFBundleTypeExtensions": ["mp4", "mov", "mkv", "m4v", "avi", "crm", "raw", "wmv", "flv", "webm", "ts", "mts", "m2ts", "wav", "mp3", "aac", "flac", "png", "jpg", "jpeg", "tiff"]
    }]
    pl["NSHighResolutionCapable"] = True
    pl["NSRequiresAquaSystemAppearance"] = False
    pl["NSAppSleepDisabled"] = True
    pl["NSSupportsAutomaticTermination"] = False
    pl["NSSupportsAutomaticGraphicsSwitching"] = True
    pl["NSDesktopFolderUsageDescription"] = "MediaEngine requires access to read and save converted videos."
    pl["NSDocumentsFolderUsageDescription"] = "MediaEngine requires access to process documents."
    pl["NSDownloadsFolderUsageDescription"] = "MediaEngine requires access to process files in Downloads."
    pl["NSRemovableVolumesUsageDescription"] = "MediaEngine requires access to encode footage from external drives and SD cards."
    pl["NSNetworkVolumesUsageDescription"] = "MediaEngine requires access to encode footage from network shares and NAS storage."
    with open(plist_path, "wb") as f:
        plistlib.dump(pl, f)
PYPLIST

APP_PATH="$HOME/Desktop/MediaEngine.app"
rm -rf "$APP_PATH"
mv "dist/MediaEngine.app" "$HOME/Desktop/"
touch "$APP_PATH"

# 9. Code Sign Locally
xattr -cr "$APP_PATH"
codesign --force --deep --sign - "$APP_PATH"

# 10. Create Standalone .DMG Installer
echo "📦 Creating Drag & Drop .dmg distribution file..."
DMG_PATH="$HOME/Desktop/MediaEngine.dmg"
rm -f "$DMG_PATH"

DMG_TMP="/tmp/dmg_staging"
rm -rf "$DMG_TMP"
mkdir -p "$DMG_TMP"

ditto "$APP_PATH" "$DMG_TMP/MediaEngine.app"
ln -s /Applications "$DMG_TMP/Applications"

cat << 'READMEEOF' > "$DMG_TMP/⚠️ FIRST-TIME USERS - READ ME.txt"
======================================================================
              MediaEngine - First-Time Setup Instructions
======================================================================

Because MediaEngine is self-built and ad-hoc signed, macOS Gatekeeper
will flag it as "damaged" or block it on first launch.

----------------------------------------------------------------------
👉 1-STEP FIX (Works on all macOS versions, including Sequoia):
----------------------------------------------------------------------

1. Drag "MediaEngine" into the "Applications" folder shortcut.

2. Open Terminal (press Cmd + Space, type "Terminal", press Enter).

3. Paste and run this command:
   xattr -cr /Applications/MediaEngine.app

✔ Done! This removes the quarantine flag. MediaEngine will now open
  immediately with a normal double-click.

----------------------------------------------------------------------
ℹ️ WHY IS THIS REQUIRED?
----------------------------------------------------------------------
macOS automatically quarantines downloaded files. Because MediaEngine is
built locally without an expensive Apple Developer certificate, macOS
falsely reports the app as "damaged". The command above simply removes
the quarantine tag so macOS treats it as a trusted local app.
======================================================================
READMEEOF

hdiutil create -volname "MediaEngine" -srcfolder "$DMG_TMP" -ov -format UDZO "$DMG_PATH"
rm -rf "$DMG_TMP"

cd "$HOME"
rm -rf "$WORKDIR" "$VENV_DIR"

echo ""
echo "=================================================="
echo "  🎉 SUCCESS! Your distributor DMG is ready:     "
echo "  $DMG_PATH"
echo "=================================================="
