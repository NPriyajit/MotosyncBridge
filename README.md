# Motosync Bridge (V1 — Media Control & Dashboard Link)

A premium iOS background utility designed to act as a bridge between an iOS device and a Honda motorcycle instrument console (`HONDA BTU`). It enables real-time background media metadata streaming and handlebar button mapping via Bluetooth Low Energy (BLE).

---

## 🛠️ Key Features (V1)

- **Automated BLE Lifecycle Management**: Performs discovery, background connection, and auto-reconnection to the `HONDA BTU` peripheral.
- **Automotive-Grade Security Handshake**: Full implementation of the reverse-engineered Honda secure handshake:
  - **Status Negotiation**: Reads status indicators to determine secure session requirements.
  - **Asymmetric Key Exchange**: Generates a 1024-bit RSA key pair on the fly, transmits the modulus, and decrypts the console-encrypted 128-bit AES session key.
  - **Symmetric Validation**: Validates the session key using AES-128 ECB mode with Modbus-style CRC-16 checksums to establish a secured link.
- **Handlebar Button Integration**: Registers custom button assignments via BLE to map the bike's tactile controls to system actions:
  - `SELECT` (Center Press) ➔ Play / Pause toggle
  - `NEXT` (Right Switch) ➔ Skip to next track
  - `PREVIOUS` (Left Switch) ➔ Skip to previous track
  - `VOLUME_UP` / `VOLUME_DOWN` ➔ System volume controls
  - `VOLUME_MUTE` ➔ Mute audio
  - `BACK` / `MENU` / `MODE_SAB` / `MODE_HU` ➔ Custom system routing points
- **Background Media Synchronization**: Intercepts active playback metadata (Title, Artist, and state) system-wide using the private `MediaRemote.framework` (with a native `MediaPlayer` fallback) and pushes a formatted 141-byte packet to the console screen.
- **Keep-Alive Heartbeat & Lease**:
  - Sends a periodic `POP_UP` GATT heartbeat packet to keep the dashboard active.
  - Secures an iOS background audio thread lease using a looping, silent WAV generator so the system does not suspend the BLE transceiver during extended background usage.

---

## 📁 Repository Structure

```
MotosyncBridge/
├── App/
│   └── MotosyncBridgeApp.swift         # Application lifecycle and environment injection.
├── AppConfiguration.swift              # Central configuration (GATT UUIDs, timeouts, settings).
├── Core/
│   ├── Bluetooth/
│   │   ├── BluetoothManager.swift      # CBCentralManager/CBPeripheral coordinator, handshakes, heartbeats.
│   │   └── SecurityHandler.swift       # Cryptographic suite (AES-128, RSA, CRC-16 Modbus).
│   └── Media/
│       ├── MediaObserver.swift         # Global background audio observer and silent background lease.
│       └── SystemMediaController.swift # Private & public media API wrappers (toggle, skip).
└── Presentation/
    └── Dashboard/
        ├── DashboardView.swift         # Premium SwiftUI Dashboard (Radar pulses, wave visualizer, metadata).
        └── DashboardViewModel.swift    # Connects media observer callbacks to Bluetooth TX queues.
```

---

## ⚙️ Configuration & Hardware Settings

Settings can be customized inside [AppConfiguration.swift](file:///Users/priyajitnayak/Documents/Projects/MotosyncBridge/MotosyncBridge/AppConfiguration.swift):

- **Target Peripheral**: Matches devices broadcasting with the local name prefix `HONDA BTU`.
- **Media Control Mode**: 
  - `.systemWide`: Leverages the private C-linkage `MediaRemote.framework` hook. Recommended for jailbroken devices, TrollStore environments, or enterprise builds to intercept Spotify, YouTube Music, etc.
  - `.appleMusic`: Native sandboxed Apple Music fallback for standard App Store compliance.

---

## 🚀 Building & Verification

Verify the codebase compiles cleanly before deploying to a physical iOS device:

```bash
# Verify simulator compilation and test targets
./scripts/verify.sh
```

---

## 🌿 Branch Information

This branch (`release/v1`) contains **strictly** the Core Bluetooth connection, handshake, handlebar button mapping, and media synchronization features. Future features (such as voice assistants, speech-to-text, and incoming call handlers) are excluded here for developers looking for a lightweight, dedicated media-bridging stack.
