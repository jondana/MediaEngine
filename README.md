# MediaEngine

MediaEngine is a high-performance, standalone batch video encoder and media analysis suite engineered specifically for macOS and Apple Silicon architecture. Built around static FFmpeg binaries and Apple's native **VideoToolbox** framework, MediaEngine delivers hardware-accelerated HEVC and H.264 transcoding, intelligent hardware-tier workload scheduling, perceptual temporal denoising, and precision color metadata preservation.

---

## Download

The latest pre-built distribution DMG can be downloaded directly from GitHub Releases:

**[Download MediaEngine.dmg](https://github.com/jondana/MediaEngine/releases/latest/download/MediaEngine.dmg)**

---

## Architectural Overview

MediaEngine is designed from the ground up to eliminate the performance bottlenecks, interface latency, and heavy dependency footprints common to generic GUI wrappers. It runs self-contained static binaries and directly leverages macOS system calls to coordinate encoding jobs across hardware execution units.

```
┌────────────────────────────────────────────────────────────────────────┐
│                              MediaEngine                               │
│  (CustomTkinter 120 FPS Sub-Pixel Quartz Kinetic Scrolling Interface)  │
└──────────────────────────────────┬─────────────────────────────────────┘
                                   │
      ┌────────────────────────────┼────────────────────────────┐
      ▼                            ▼                            ▼
┌──────────────┐         ┌───────────────────┐         ┌─────────────────┐
│ Media        │         │ Hardware Topology │         │ Audio & Subtitle│
│ Inspector    │         │ & Concurrency     │         │ Stream Mapping  │
│ (ffprobe JSON│         │ Scheduler         │         │ (Passthrough &  │
│ Stream Parse)│         │ (sysctl Profiling)│         │ Conforming)     │
└──────────────┘         └─────────┬─────────┘         └─────────────────┘
                                   │
                                   ▼
      ┌─────────────────────────────────────────────────────────┐
      │               Perceptual Processing Pipeline             │
      │  • Asymmetric Luma/Chroma Temporal Filter (atadenoise)   │
      │  • Alpha Channel Detection & Premultiplication Pipeline │
      │  • HDR10 / HLG Color Science & QuickTime 'colr' Atom     │
      └────────────────────────────┬────────────────────────────┘
                                   │
                                   ▼
      ┌─────────────────────────────────────────────────────────┐
      │               Apple VideoToolbox / CPU Core             │
      │  • M-Series Media Engine Concurrency Dispatcher         │
      │  • Staggered Launch & Hardware Recovery Watchdogs       │
      │  • 10-Bit 4:2:2 (p210le) / 10-Bit 4:2:0 (p010le)        │
      └─────────────────────────────────────────────────────────┘
```

---

## Key Systems & Under-the-Hood Mechanics

### 1. Hardware Topology & Dynamic Concurrency Allocation

Unlike conventional encoding tools that assign a fixed number of simultaneous jobs, MediaEngine queries the macOS kernel via `sysctl` to detect the exact Apple Silicon generation and chip tier:

* **Apple M-Series Base / Pro**: Identified as having 1 dedicated VideoToolbox encode engine.
* **Apple M-Series Max**: Identified as having 2 parallel hardware encode engines.
* **Apple M-Series Ultra**: Identified as having 4 parallel hardware encode engines.

MediaEngine couples this hardware profile with physical memory interrogation (`hw.memsize` / `SC_PHYS_PAGES`) and resolution-based resource weighting to prevent memory exhaustion, bus contention, and hardware encoder timeouts (`-12903`, `-12912`, `-17691`).

#### Resolution Weighting Matrix

Before jobs are queued for execution, the stream geometry is probed:

| Resolution Category | Definition | Resource Weight | Concurrency Impact |
| :--- | :--- | :--- | :--- |
| **8K UHD / DCI** | $\ge 7000 \times 4000$ or $\ge 25\text{ MP}$ | **6 Units** | Restricts concurrent execution; throttled by strict chip-tier quotas |
| **4K UHD / DCI** | $\ge 3500 \times 2000$ or $\ge 7\text{ MP}$ | **2 Units** | Balanced distribution across media engines |
| **1440p / 1080p / SD** | $< 3500 \times 2000$ | **1 Unit** | Maximizes throughput across available cores |

#### Concurrency Modes

* **Sequential**: Runs 1 active job at a time, allocating maximum system bandwidth to single-file completion.
* **Balanced**: Matches hardware engine capabilities ($2\times \text{media engines}$, capping total weight relative to chip tier).
* **Turbo**: Exploits unified memory bandwidth on high-memory systems (up to $3\times \text{media engines}$ on Max/Ultra configurations, scaled automatically on machines with $\le 8\text{ GB}$ RAM).

To prevent bus locking during initialization, MediaEngine employs an **asynchronous launch stagger** (800ms delay between 8K instances; 200ms between standard instances) coupled with an automatic fallback mechanism that traps stalled sessions and automatically re-routes them through software decoding or extended exponential backoff.

---

### 2. Perceptual Temporal Denoising & Bitrate Optimization

Digital camera sensors introduce high-frequency, non-correlated noise—most noticeably in shadows and flat color fields. Modern block-based video encoders (HEVC and AVC) treat random sensor noise as genuine motion detail. Consequently, a massive percentage of the encoder's bitrate budget is spent encoding temporal artifacts rather than structural image data.

MediaEngine implements a custom-tuned `atadenoise` (Adaptive Temporal Averaging Denoiser) stage that operates across multi-frame temporal windows:

```
Raw Frame Sequence (N-2, N-1, N, N+1, N+2)
                   │
                   ▼
┌─────────────────────────────────────────────────────────────────┐
│              Planar Pixel Representation Conversion             │
│                (yuv422p10le / yuv420p10le)                      │
└──────────────────┬─────────────────────────────┬────────────────┘
                   │                             │
                   ▼                             ▼
       Luminance Plane (Y)             Chrominance Planes (U/V)
    ┌────────────────────────┐      ┌────────────────────────┐
    │ Conservative Filtering │      │  Aggressive Smoothing  │
    │   Threshold A: 1.2x    │      │   Threshold A: 2.0x    │
    │   Threshold B: 3.5x    │      │   Threshold B: 5.5x    │
    └──────────────┬─────────┘      └────────────┬───────────┘
                   │                             │
                   └──────────────┬──────────────┘
                                  │
                                  ▼
┌─────────────────────────────────────────────────────────────────┐
│     Preserved Edges & Textures + Cleared Color Noise Floor      │
│      Result: Drastically lower encoder entropy = smaller files   │
└─────────────────────────────────────────────────────────────────┘
```

#### Asymmetric Luma vs. Chroma Tuning

Human visual perception is substantially more sensitive to high-frequency spatial variation in luminance than in chrominance. MediaEngine deliberately targets sensor noise by decoupling luma and chroma thresholds:

* **Luma Thresholds (`0a`, `0b`)**: Kept conservative ($1.2\times$ and $3.5\times$ scaling) to protect edge sharpness, fine hair, fabric weave, and micro-contrast.
* **Chroma Thresholds (`1a`, `1b`, `2a`, `2b`)**: Filtered aggressively ($2.0\times$ and $5.5\times$ scaling) to eliminate low-light color speckling, magenta/green blotchiness, and temporal chroma crawling.

By eliminating random chroma variation between successive frames, inter-frame motion vectors achieve significantly higher predictive accuracy. This yields **file size reductions between 25% and 60%** without noticeable softening of fine image details.

#### Automatic HDR Transfer Bypass

Temporal averaging algorithms designed for gamma curves will compress dynamic range and clip highlights when applied to non-linear High Dynamic Range transfer functions. MediaEngine automatically inspects the input stream's color transfer characteristics: if **SMPTE 2084 (PQ)** or **ARIB STD-B67 (HLG)** is detected, temporal denoising is bypassed, safeguarding pristine highlight roll-off and shadow delineation.

---

### 3. Apple VideoToolbox Hardware Pipeline

MediaEngine includes deep runtime integration with Apple's VideoToolbox framework:

* **Dynamic 10-Bit 4:2:2 Pro Capability Detection**: Probes the hardware at startup (`nullsrc` pipeline test with `-profile:v main42210 -pix_fmt p210le`). If supported by the silicon, 10-Bit 4:2:2 encoding is available; otherwise, the interface cleanly constrains presets to 10-Bit 4:2:0 (`p010le`) or 8-Bit 4:2:0 (`nv12`).
* **Spatial Adaptive Quantization (`spatial_aq`)**: When supported by the underlying FFmpeg build and hardware, Spatial AQ is engaged to dynamically distribute bit allocation across high-complexity spatial regions, preventing macroblocking in complex textures.
* **Hardware Recovery Watchdog**: If a VideoToolbox session hangs or becomes unresponsive during high-throughput batches, a background thread intervenes, issues a clean `SIGKILL` to the isolated process group, cleans temporary lock references, and re-dispatches the file with software fallbacks.

---

### 4. Alpha Channel & Transparency Handling

Standard hardware and CPU encoding pipelines strip or mishandle alpha transparency. When MediaEngine detects an alpha channel in the input stream (`yuva`, `rgba`, `bgra`, `ya8`, etc.):

1. CPU and H.264 options are overridden to route the file through `hevc_videotoolbox`.
2. Output containers are conformed to `.mov` (Apple QuickTime).
3. The stream is evaluated for premultiplication metadata (`alpha_mode`). If non-premultiplied, an in-place premultiplication filter (`premultiply=inplace=1`) is inserted to prevent dark fringing along anti-aliased boundaries.
4. Frames are encoded with `-pix_fmt bgra -tag:v hvc1 -vtag hvc1 -alpha_quality 0.75`, ensuring full transparency preservation inside macOS, Final Cut Pro, DaVinci Resolve, and Adobe Premiere Pro.

---

### 5. Professional Color Science & Metadata Passthrough

To ensure accurate playback between QuickTime Player, web browsers, and non-linear editors, MediaEngine enforces strict NCLX color tagging:

* **Color Space Parameters**: Automatically parses and conforms `color_primaries`, `color_trc`, and `colorspace` (e.g., BT.709, BT.2020, SMPTE 240M, DCI-P3).
* **Mastering Display & Light Level Metadata**: Preserves SMPTE 2086 mastering display coordinates (display primaries, white point, min/max luminance) and Content Light Level metrics (MaxCLL / MaxFALL).
* **QuickTime Atom Injection**: Writes the NCLX color record directly into the container header (`-movflags +write_colr`), eliminating the common gamma shift bug in macOS QuickTime playback.

---

### 6. Built-in Media Inspector

MediaEngine features an integrated, non-blocking media inspector that extracts deep stream metadata using static `ffprobe` JSON parsing:

* **Container Analysis**: Format identification, global bitrate, container creation timestamps, encoder/writing application signatures.
* **Video Streams**: Profile, level, pixel format, calculated bits-per-pixel (BPP), display aspect ratio, frame rate mode (CFR vs. VFR), and full color parameter matrices.
* **Audio & Auxiliary Streams**: Channel configurations (down to individual surround layouts), audio sample rates, stream bitrates, embedded subtitle formats, and cover artwork attachments.
* **Raw JSON View**: Provides raw programmatic output for quality control verification and debugging.

---

## Installation

Because MediaEngine is independently built and distributed without an Apple Developer certificate, macOS Gatekeeper applies a quarantine attribute to the application bundle upon download.

### Standard Setup

1. Download **`MediaEngine.dmg`** from the [Releases](https://github.com/jondana/MediaEngine/releases/latest) section.
2. Open the DMG and drag **MediaEngine.app** into your **Applications** folder.
3. Open **Terminal** (`Cmd + Space`, type `Terminal`, hit `Enter`).
4. Execute the following command to strip the quarantine flag:
   ```bash
   xattr -cr /Applications/MediaEngine.app
   ```
5. Launch **MediaEngine** directly from Applications, Spotlight, or Launchpad.

---

## Building from Source

MediaEngine can be compiled directly into a self-contained `.app` and distributor `.dmg` using the provided build automation script.

### Prerequisites

* macOS 11.0 (Big Sur) or higher (Apple Silicon or Intel).
* Python 3.11, 3.12, or 3.13 with Tkinter support (installable via Homebrew: `brew install python-tk`).
* Xcode Command Line Tools (`xcode-select --install`).

### Build Steps

1. Clone this repository or download the source:
   ```bash
   git clone https://github.com/jondana/MediaEngine.git
   cd MediaEngine
   ```

2. Make the build script executable and run it:
   ```bash
   chmod +x build_encoder.sh
   ./build_encoder.sh
   ```

The script will automatically:
* Verify or download genuine static FFmpeg and FFprobe binaries compiled with VideoToolbox support.
* Construct an isolated Python virtual environment and install PyInstaller, CustomTkinter, Pillow, and TkinterDnD2.
* Package the application bundle with full Retina icons (`.icns`) and appropriate `Info.plist` entitlement descriptions.
* Sign the resulting `.app` bundle ad-hoc.
* Output a finished, ready-to-distribute **`MediaEngine.dmg`** onto your Desktop.

---

## Supporting the Project

If MediaEngine streamlines your video workflow or saves you rendering time, consider supporting ongoing development:

[![Support on Ko-fi](https://img.shields.io/badge/Ko--fi-Support%20the%20Project-orange?style=for-the-badge&logo=kofi)](https://ko-fi.com/jondana)

---

## License

This project is licensed under the terms of the GPL License. Embedded static FFmpeg binaries are licensed under the LGPL/GPL depending on configuration flags.
