# iRig BlueBoard Replacement for macOS

A lightweight, native, Apple Silicon-compatible replacement app for the IK Multimedia iRig BlueBoard companion app on macOS. 

This app runs natively on modern macOS (macOS 11.0 through macOS 27 and beyond on Apple Silicon) and acts as a direct drop-in replacement. It connects to the BlueBoard, performs the proprietary Bluetooth LE challenge-response handshake, drives the physical LEDs/backlight, and maps button presses and expression pedals to a virtual CoreMIDI source called `"iRig BlueBoard"`.

---

## Features

- **Apple Silicon Native**: Works on Apple Silicon (M1/M2/M3/M4/etc.) and modern Intel Macs.
- **Visual State GUI**: Standard window showing connection status, battery percentage, active bank, the last clicked footswitch, and real-time sweep indicators for external expression pedals.
- **Dynamic MIDI Mapping (Program Switch Mode)**:
  - Buttons **A**, **B**, **C**, **D** send standard MIDI **Program Change** (PC) messages on all 16 MIDI channels.
  - The active button's physical LED lights up.
- **Bank Switching**:
  - Press and hold button **A** for 3 seconds to change to the **Next Bank** (Bank Up).
  - Press and hold button **B** for 3 seconds to change to the **Previous Bank** (Bank Down).
  - All four LEDs flash on the board to visually confirm bank switching.
  - Bank bounds support Banks 0–31 (triggering PC messages 0–127).
- **Expression Pedals**:
  - Automatically scales external expression pedals from `0–255` (analog) to `0–127` (MIDI CC).
  - Maps **Pedal 1** to **CC 7 (Volume)** and **Pedal 2** to **CC 11 (Expression)**.
  - Sends CC updates to all 16 MIDI channels.

---

## Technical Specifications

The BlueBoard uses the proprietary GATT Service `6B872736-F93E-4176-B3B1-143636CABB00`.

### Handshake Protocol (CABB09)
Upon connection, the BlueBoard issues a 20-byte random challenge on characteristic `CABB09` and will disconnect if the correct response is not written within ~2 seconds. The response is calculated by XORing each byte of the challenge with the static 20-byte key:
```swift
[0xf2, 0x63, 0xee, 0xb6, 0xa7, 0x12, 0x05, 0x50, 0xb1, 0x57, 0x21, 0x6a, 0x2e, 0xfa, 0xc3, 0x9c, 0x7d, 0xb7, 0x76, 0xbc]
```

### Characteristic Mapping
- **`CABB01` (Switches / Notify)**: Button index (0–3) and pressed state (`0xFF` = pressed, `0x00` = released).
- **`CABB02` (LEDs / Write)**: Toggles button lights. Byte payload: `[button_index, status_byte]`.
- **`CABB03` (Ext Switches / Notify)**: Expression pedal index (0–1) and raw position value (`0x00–0xFF`).
- **`CABB05` (Backlight / Write)**: Toggles general board backlight. Byte payload: `[status_byte]`.
- **`2A19` (Battery / Read, Notify)**: Battery percentage value (`0–100`).

---

## Installation & Build Instructions

### Prerequisites
- macOS 11.0 or newer.
- Swift compiler installed (included with Xcode Command Line Tools).

### 1. Build from Source
Run the build script in the root of the repository:
```bash
./build.sh
```

This script will:
- Compile `main.swift` with optimization.
- Package it into a native macOS app bundle under `/Applications/iRig BlueBoard Replacement.app`.
- Retrieve the original app's high-resolution icon (`Icon.icns`) and apply it.

### 2. Grant Bluetooth Permissions
1. Turn on your iRig BlueBoard in **Mode A** (hold the **A** button while switching on).
2. Double-click **iRig BlueBoard Replacement** in your `/Applications` directory.
3. macOS will prompt you to grant Bluetooth permission to the application. Click **Allow** or **OK**.
4. The window will open and connect immediately.

---

## Repository Structure

- `main.swift`: Core application source file containing the Bluetooth connection engine, MIDI UMP transmission logic, and AppKit GUI.
- `Info.plist`: Application metadata configuration.
- `build.sh`: Automated compilation and installation script.
- `README.md`: Project documentation.
