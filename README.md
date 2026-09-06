# 🚀 MediaEngine

A fast, standalone batch video encoder and inspector designed specifically for Apple Silicon Macs. Powered by macOS **VideoToolbox** hardware media engines and static FFmpeg.

---

## ⬇️ Download

Download the latest standalone installer from the [**Releases Page**](https://github.com/jondana/MediaEngine/releases/latest):

👉 **[Download MediaEngine.dmg](https://github.com/jondana/MediaEngine/releases/latest/download/MediaEngine.dmg)**

---

## ✨ Features

- **Apple Silicon Hardware Acceleration**: Uses hardware VideoToolbox encoding for HEVC and H.264.
- **ProRes & Multi-Engine Scaling**: Automatically scales concurrent encode workers based on your Mac chip tier (Base, Pro, Max, Ultra).
- **Pro Color Support**: Preserves HDR10 (PQ), HLG, BT.2020 wide color gamut metadata, and side-data parameters.
- **Deep Media Inspector**: Detailed breakdown of bitrates, color profiles, audio tracks, and container characteristics.
- **Integrated Pre-filtering**: Hardware-aware temporal spatial denoise and alpha-channel preservation.
- **Fully Standalone**: Bundled static binaries; no separate Homebrew or FFmpeg installation required.

---

## 🛠️ Installation & First-Time Launch

Because MediaEngine is independently built and ad-hoc signed, macOS Gatekeeper may flag it as "unverified" or "damaged" on first open. 

### 1-Step Fix:
1. Open **`MediaEngine.dmg`** and drag **MediaEngine.app** into your **Applications** folder.
2. Open **Terminal** (`Cmd + Space`, type `Terminal`, hit `Enter`).
3. Paste and run:
   ```bash
   xattr -cr /Applications/MediaEngine.app
   ```
4. Double-click **MediaEngine** in Applications. It will launch normally.

---

## 🏗️ Building from Source

To compile the standalone app bundle and DMG yourself:
```bash
chmod +x build_encoder.sh
./build_encoder.sh
