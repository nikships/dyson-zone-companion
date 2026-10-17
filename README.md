<div align="center">

# Dyson Zone Companion

A macOS menu bar app for Dyson Zone headphones.

![License](https://img.shields.io/github/license/nikships/dyson-zone-companion?style=for-the-badge)
![Platform](https://img.shields.io/badge/macOS-14%2B-black?style=for-the-badge&logo=apple)
![Swift](https://img.shields.io/badge/Swift-5.9-F05138?style=for-the-badge&logo=swift&logoColor=white)

</div>

## What is this?

Dyson only ships a phone app for the Zone. This app puts the controls in your Mac's menu bar:

- **Noise control:** noise cancelling, conversation, transparency
- **EQ presets:** Enhanced, Bass boost, Neutral
- **Battery:** percent and charging state
- **Airflow:** off, rest, light, moderate, auto (needs the visor; not tested yet)
- **Audio:** connect and disconnect, signal strength, volume, and an option that keeps the Mac mic as the input so macOS does not drop the headphones into low-quality call mode

It talks to the headphones over the same Bluetooth LE control channel the MyDyson app uses. Audio still goes over normal Bluetooth.

This is an unofficial project. It is not affiliated with or endorsed by Dyson.

## Quick Start

Requires macOS 14 or later and the Xcode command line tools. Pair the Zone in System Settings > Bluetooth first.

```sh
git clone https://github.com/nikships/dyson-zone-companion.git
cd dyson-zone-companion
./build.sh --install
```

This builds the app, signs it ad hoc, installs it to `~/Applications`, and launches it. Look for the headphones icon in the menu bar.

### First run

1. Click the icon, then **Sign in to Dyson…**.
2. Press **Email me a code**, then enter the code and your MyDyson password.

The app fetches the headphones' long-term key from your Dyson account once. The key is stored in `~/Library/Application Support/DysonZone/credentials.json` (file mode 600, not encrypted). Your password is never saved. Signing out deletes the key.

### One controller at a time

The Zone accepts a single BLE control connection. While the MyDyson app on your phone is connected, the panel shows "In use by another device". Turn off Bluetooth on the phone, or close MyDyson, and the Mac connects within a few seconds.

Log file: `~/Library/Logs/DysonZone.log`.

## Project Structure

```
dyson-zone-companion/
├── Resources/
│   └── Info.plist
├── Sources/DysonZone/
│   ├── Dyson/
│   │   ├── Cloud.swift        Dyson account login and key fetch
│   │   ├── Crypto.swift       Handshake encryption
│   │   ├── Framing.swift      Message fragmenting and reassembly
│   │   └── ZoneLink.swift     BLE connection, ANC, EQ, battery, airflow
│   ├── App.swift              Menu bar panel and sign-in window
│   ├── AppModel.swift
│   ├── AudioDevices.swift     CoreAudio output, input, volume
│   └── Headphones.swift       Classic Bluetooth link and audio state
├── docs/
│   └── PROTOCOL.md
├── LICENSE
├── Package.swift
├── README.md
└── build.sh
```

## Documentation

| Resource | Description |
|----------|-------------|
| [docs/PROTOCOL.md](docs/PROTOCOL.md) | The Zone's BLE services, handshake, attribute IDs and characteristics |

The protocol was reverse engineered from the MyDyson Android app (6.4.26381). The shared Dyson framework is documented in more depth by [homebridge-dyson-solarcycle-morph](https://github.com/rummeyer/homebridge-dyson-solarcycle-morph/blob/main/docs/PROTOCOL.md), which this project's handshake follows.

## Contributing

Issues and pull requests are welcome. Useful things to pick up: decoding the remaining attributes (air quality, noise levels, head detection, visor state), testing airflow with the visor attached, and other Zone firmware versions. Some Zone units may not expose every characteristic.

## License

MIT. See [LICENSE](LICENSE).
