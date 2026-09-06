<img width="1578" height="1908" alt="Screenshot 2026-09-05 at 10 24 19 PM" src="https://github.com/user-attachments/assets/5e80682b-140a-457d-9ddd-a89411d8dfa8" />

# MediaEngine

A dedicated, high-performance batch video encoder and deep media inspector engineered from the ground up for macOS and Apple Silicon. MediaEngine leverages native Apple VideoToolbox hardware encoding blocks, intelligent dynamic thread/resolution scheduling, and perceptual temporal noise reduction to produce ultra-compact, visually lossless masters and edit-ready files.

[![Platform: macOS](https://img.shields.io/badge/Platform-macOS%2011.0%2B-000000.svg?style=flat-square&logo=apple)](https://www.apple.com/macos/)
[![Architecture: Apple Silicon](https://img.shields.io/badge/Architecture-Apple%20Silicon%20(Universal)-46748A.svg?style=flat-square)](https://support.apple.com/en-us/HT211814)
[![License: GPL-3.0](https://img.shields.io/badge/License-GPL--3.0-blue.svg?style=flat-square)](https://www.gnu.org/licenses/gpl-3.0.en.html)
[![Support on Ko-fi](https://img.shields.io/badge/Support-Ko--fi-FF5E5B.svg?style=flat-square&logo=kofi)](https://ko-fi.com/jondana)

---

## The Origin of MediaEngine

MediaEngine was born out of frustration with existing macOS encoding utilities when handling high-resolution cinema footage in mobile post-production workflows.

When shooting 8K Canon Cinema RAW Light or C-Log3 on a Canon EOS R5, storage requirements and compute overhead quickly become prohibitive. Editing natively on location requires either massive external RAID arrays or lengthy offline proxy generation workflows. Transcoding batches of hundreds of raw takes through standard tools presented continuous roadblocks:

* **HandBrake** offers hardware acceleration, but enforces an unskippable preliminary clip scan and preview generation phase for every single queued file. When importing hundreds of clips from multiple cards, this pre-scan can lock up the system for tens of minutes before a single frame is encoded.
* **General-purpose encoders** frequently omit native Apple VideoToolbox 10-bit 4:2:2 hardware pipelines, lack accurate color container tagging (`colr` and `nclx` atom synthesis), or drop crucial HDR10 / mastering display metadata entirely.
* **Interface overload** in existing tools buries critical parameters under dozens of nested tabs and technical checkboxes that have little to no positive impact on final image quality or compression ratio.

MediaEngine was designed as the antidote: a clean, robust, and zero-latency batch processing tool with no preview stalls and no bloated menus. It exposes only the parameters that genuinely impact image fidelity, utilizing Apple's hardware encoding engines alongside Constant Quality targets. 

This pipeline compresses high-bitrate 8K C-Log3 footage down to roughly 30–40 Mbps while retaining 10-bit color accuracy, smooth grading headroom, and instant native hardware playback in Final Cut Pro on an Apple Silicon MacBook Pro. An entire shoot's library can remain on internal storage, making a fully mobile, high-resolution editing workflow practical without dedicated proxy files.

---

## Architectural Overview & Under the Hood

### 1. Hardware Silicon Profiling & Dynamic Concurrency Scheduling

Apple Silicon processors contain dedicated hardware media engines separate from CPU and GPU cores. The number of active hardware video encoders scales across chip tiers:
* **Base (M1/M2/M3/M4):** 1 Encode Engine
* **Pro:** 1 Encode Engine
* **Max:** 2 Encode Engines
* **Ultra:** 4 Encode Engines

Running too few concurrent encodes underutilizes the silicon, while running too many jobs causes VideoToolbox context thrashing, frame dropouts, out-of-memory crashes, or hardware lockouts (such as errors `-12905`, `-12915`, and `-17691`).

```
[ Ingest Queue ]
       │
       ▼
[ Probe & Categorize ]
  ├── 8K Footage  ───────►  Weight: 6 Units (Cap: 1 per Engine)
  ├── 4K Footage  ───────►  Weight: 2 Units
  └── HD / 1440p  ───────►  Weight: 1 Unit
       │
       ▼
[ Dynamic Budgeting Engine ] ◄── Evaluates Chip Tier & Active Load
       │
       ├─► Sequential Mode: 1 Job Strict
       ├─► Balanced Mode:   Optimal Silicon Saturation (2 × Multiplier)
       └─► Turbo Mode:      Maximum Throughput with RAM Guardrails
       │
       ▼
[ Staggered Hardware Dispatch ] (Avoids simultaneous VT initialization)
```

MediaEngine automates load balancing through an internal resource scheduler:

* **System Interrogation:** On launch, the engine probes system architecture via `machdep.cpu.brand_string` and registers available memory using `hw.memsize`.
* **Capability Validation:** The application dynamically runs isolated micro-tests against `hevc_videotoolbox` to confirm hardware-level 10-bit 4:2:2 (`p210le` / `main42210`) support and `spatial_aq` availability. If a given Mac tier lacks 4:2:2 hardware write support, MediaEngine safely falls back to high-profile 10-bit 4:2:0 without crashing or dropping bit depth.
* **Weighted Resolution Budgeting:** Not all streams exert equal pressure on the media blocks. MediaEngine assigns resource units dynamically:
  * **8K Streams:** 6 Resource Units (strictly capped to 1 per engine to preserve cache locality).
  * **4K Streams:** 2 Resource Units.
  * **1080p / 1440p Streams:** 1 Resource Unit.
* **Staggered Dispatch:** Concurrent hardware jobs are staggered by up to 800 ms to eliminate initial driver lock contention during pipeline allocation.
* **Process Throttling & Live Rebalancing:** When system resource thresholds shift or a user adjusts concurrency between *Sequential*, *Balanced*, and *Turbo*, background jobs are paused or resumed cleanly using low-level POSIX signals (`SIGSTOP` / `SIGCONT`), preventing memory pressure spikes.

---

### 2. Perceptual Noise Reduction & Bitrate Conservation

Raw camera sensors and high-ISO log profiles exhibit microscopic temporal grain and high-frequency chrominance variance. 

Modern block-based video codecs (HEVC / AVC) allocate immense amounts of data attempting to mathematically reconstruct random, fluctuating noise across frames. Macroblocks struggle to find coherent motion vectors between frames, forcing the encoder to fall back on expensive intra-coded blocks and bloating bitrates with visual entropy that conveys no real image information.

```
Raw Camera Input ──► [ Split Frequency Analysis ]
                           │
                           ├── Luma Channel (Y')   ──► Conservative Thresholds (Sharp Detail)
                           └── Chroma Channels (UV) ──► Aggressive Temporal Averaging (Grain Removal)
                                                            │
                                                            ▼
                                               Cleaned Inter-Frame Prediction
                                                            │
                                                            ▼
                                            Drastically Lower Bitrate / Smaller File
```

MediaEngine incorporates an adaptive temporal averaging pipeline (`atadenoise`) operating in a high-depth planar color space (`yuv422p10le` / `yuv420p10le`), parameterized by split luma/chroma thresholds:

$$\text{Threshold}_{\text{Luma}} = k \cdot [1.2, 3.5]$$

$$\text{Threshold}_{\text{Chroma}} = k \cdot [2.0, 5.5]$$

* **Chroma-Biased Attenuation:** Human vision is substantially more sensitive to edge sharpness (luma) than high-frequency chromatic variations (chroma). MediaEngine weights chrominance filtering significantly higher than luminance filtering. This strips digital color blotches and sensor noise from shadows while keeping fine physical textures and skin tones intact.
* **Motion-Adaptive Temporal Window:** The temporal sample window scales dynamically from 5 to 9 successive frames depending on the selected intensity. Moving subjects remain free of ghosting artifacts, while static backgrounds settle into clean, easily compressible fields.
* **HDR Safety Bypass:** Applying temporal averaging filters to non-linear High Dynamic Range transfer functions (SMPTE ST 2084 / PQ or ARIB STD-B67 / HLG) can cause highlight stepping and shadow clipping. MediaEngine inspects incoming color metadata and automatically suspends spatial-temporal filtering on HDR inputs to maintain photometric accuracy.

---

### 3. Native Final Cut Pro Compatibility & Constant Quality Encoding

Rather than using bitrate caps that under-allocate complex scenes and waste bandwidth on simple ones, MediaEngine drives VideoToolbox via Constant Quality mode (`-q:v`).

* **Predictable Visual Fidelity:** Complex high-frequency scenes (water, foliage, fine textiles) automatically receive higher bit allocation, while simple gradients and static interviews drop to lower bitrates without macroblocking.
* **Hardware Decoding in Final Cut Pro:** Apple's VideoToolbox encoder produces standards-compliant bitstreams tagged with proper four-character codes (`hvc1` / `avc1`). Files imported into Final Cut Pro or DaVinci Resolve bypass software translation layers and play directly through Apple Silicon's hardware decoding hardware.
* **Preserving Alpha Channels:** When transparent assets (ProRes 4444, QuickTime Animation) are processed, MediaEngine identifies embedded alpha channels, premultiplies transparency, and routes the stream to 32-bit `bgra` VideoToolbox containers, generating compact HEVC files with fully intact transparency.

---

### 4. Color Science and Metadata Fidelity

Maintaining broadcast and archival standards requires strict color container preservation. MediaEngine reads, maps, and writes explicit NCLX and mastering display atoms:

| Parameter | Standard Input Values | FFmpeg & VideoToolbox Parameter Mapping |
| :--- | :--- | :--- |
| **Color Primaries** | BT.709, BT.2020, DCI-P3 (Display P3) | `color_primaries` / ISO/IEC 23001-4 NCLX code points |
| **Transfer Function** | BT.709, sRGB, PQ (ST 2084), HLG (BT.2100) | `color_trc` / Exact EOTF curve declaration |
| **Matrix Coefficients** | BT.709, BT.2020 non-constant, SMPTE 170M | `colorspace` / Chrominance matrix conversion tags |
| **HDR Static Metadata** | SMPTE ST 2086 (Mastering Display) | Parsed chromaticity coordinates $(x,y)$ and min/max luminance |
| **Light Levels** | CTA-861.3 Content Light Level | Parsed MaxCLL / MaxFALL injection |
| **Timecode** | Drop-Frame / Non-Drop Frame SMPTE TC | Explicit `-timecode` synthesis and passthrough |

---

## Features

* **Hardware-Accelerated Encoding:** Full support for Apple VideoToolbox HEVC (10-bit 4:2:2, 10-bit 4:2:0, 8-bit) and H.264.
* **Software Fallback (CPU):** Integrated `libx265` and `libx264` support with deep tuning parameters (AQ modes, psycho-visual rate-distortion, SAO disabling) for systems requiring software-level control.
* **Deep Media Inspector:** Detailed inspection tab detailing container profiles, bit depths, chroma sub-sampling formats, track indices, audio channel layouts, HDR side data, and raw JSON streams.
* **Zero Host Dependencies:** Ships with true static builds of FFmpeg and FFprobe compiled with VideoToolbox bindings; no Homebrew, Python, or command-line tools required for the end user.
* **Intelligent Subtitle & Audio Handling:** Automatic multi-stream audio mapping (copying uncompressed/AAC streams when appropriate, transcoding complex multi-channel formats) and subtitle track normalization.
* **Fluid 120 FPS UI:** Built using CustomTkinter with custom Quartz-based kinetic physics scrolling engines for responsiveness under heavy loads.

---

## Installation

### Pre-Built Binaries (macOS 11.0+)

1. Download the latest `MediaEngine.dmg` from the [**Releases Page**](https://github.com/jondana/MediaEngine/releases/latest).
2. Open the disk image and drag **MediaEngine.app** to your `/Applications` directory.

#### Gatekeeper Initialization (One-Time Setup)
Because MediaEngine is independently built and ad-hoc signed, macOS Gatekeeper may flag it as unverified on first launch. To permit execution:

1. Open **Terminal** (`Cmd + Space`, type `Terminal`, hit `Enter`).
2. Run the following command:
   ```bash
   xattr -cr /Applications/MediaEngine.app
   ```
3. MediaEngine will now open immediately via standard double-click or Spotlight.

---

## Building from Source

MediaEngine provides an automated build script that handles virtual environments, PyInstaller packaging, static FFmpeg binary acquisition, and `.dmg` staging.

### Prerequisites
* macOS 11.0 Big Sur or later (Apple Silicon recommended).
* Python 3.11, 3.12, or 3.13 with Tkinter support:
  ```bash
  brew install python-tk
  ```

### Build Execution

1. Clone the repository:
   ```bash
   git clone https://github.com/jondana/MediaEngine.git
   cd MediaEngine
   ```
2. Make the build script executable and run:
   ```bash
   chmod +x build_encoder.sh
   ./build_encoder.sh
   ```
3. Upon completion, the compiled, standalone `MediaEngine.dmg` and application bundle will be placed on your Desktop.

---

## Support & Contributions

MediaEngine is completely free and open-source software. If this tool saves you time, simplifies your editing setup, or helps your production pipeline, consider supporting ongoing development:

[![Support on Ko-fi](https://img.shields.io/badge/Support%20on-Ko--fi-FF5E5B?style=for-the-badge&logo=kofi&logoColor=white)](https://ko-fi.com/jondana)

Bug reports, feature requests, and pull requests are welcome on GitHub.

---

## License

MediaEngine is licensed under the terms of the **GNU General Public License v3.0 (GPL-3.0)**. You are free to inspect, modify, and redistribute the source code under the provisions of the license. See the [LICENSE](LICENSE) file for complete details.
