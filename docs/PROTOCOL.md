# Dyson Zone BLE protocol (as implemented here)

Product code `machine571` (model WP01, type 571). Classic Bluetooth carries audio only (A2DP,
AVRCP, HFP); all control is BLE GATT.

The framework is shared with other Dyson Bluetooth products. For the generic parts (framing,
handshake, attribute channel) see
<https://github.com/rummeyer/homebridge-dyson-solarcycle-morph/blob/main/docs/PROTOCOL.md>.
Everything below was verified against a live Zone unless marked otherwise.

## Services

| Service | Characteristics |
| --- | --- |
| `2DD10010-1C37-452D-8979-D1B4A787D0A4` | `2DD10011` auth messages, `2DD10013` RSSI |
| `2DD10020-…` | `2DD10021` attribute channel |
| `2DD12000-…` | Zone characteristics, below |

Only the `2DD10010` service is advertised, and only connectable while no other central holds the
link.

## Auth

1. Log in to the Dyson cloud (`/v3/userregistration/email/{userstatus,auth,verify}`), list devices,
   `GET /v1/lec/<serial>/ltk` with `X-Dyson-ApiAuthCode: 80541406`.
2. Per connection: `0x0A` product info, then `0x06` (account GUID, sealed nonce), `0x07` back,
   `0x08` (sealed challenge), `0x26` established. Key is HKDF-SHA256(LTK, info
   `USER_AUTH_AES\0\0\0`)[0:16]; `seal` is IV, AES-128-CBC without padding, HMAC-SHA256 over the
   ciphertext. Checked against the reference vectors.

Messages are fragmented to 20 bytes: first header `0x80 | (fragments - 1)`, later headers are the
fragment index.

## Attribute channel (`2DD10021`)

`0x90` get, `0x91` value (`id(2) status len(2) value`), `0x93` set (`id(2) len(2) value`), `0x94` ack,
`0x96` subscribe, `0x97` report (`id(2) len(2) value`), `0x98` subscribe ack. IDs are little-endian.

| ID | Meaning |
| --- | --- |
| `0x400A` | ANC mode: 0 noise cancelling, 1 conversation, 2 transparency, 3 off (4, 5 exist, unused) |
| `0x401A` | Battery state: 0 full, 1 normal, 2 low, 3 insufficient, 4 critical, 5 shutdown |
| `0x4010` | Volume limiter |
| `0x4011` | Audio status |
| `0x4012` | Conversation mode |
| `0x4006` | Filter presence |
| `0x4009` | Market AQ adjustment factor (100) |
| `0x400B` | EQ preset: 0 Enhanced, 1 Bass boost, 2 Neutral (3 exists in the app enum, unused in its UI) |
| `0x4013`, `0x4014`, `0x4015`, `0x4019`, `0x401B`, `0x401C`, `0x400C`, `0x4008` | read fine, not decoded |

## `2DD12000` characteristics

| UUID | Flags | Meaning |
| --- | --- | --- |
| `2DD12001` | read, write-no-response, notify | Fan speed 0 off, 1 rest, 2 light, 3 moderate |
| `2DD12002` | read, write-no-response, notify | Fan auto mode (bool) |
| `2DD12003` | read, notify | Actual fan speed (0 to 3) |
| `2DD1200B` | read, notify | Charger present |
| `2DD1200C` | read, notify | 2 bytes LE, read `0x16a8`, not decoded |
| `2DD12016` | read, notify | Charging state: 0 none, 1 pre, 2 fast, 3 termination |
| `2DD1201D` | read, notify | Air quality and audio health block (SPL, temperature, humidity, VOC) |
| `2DD1201E` | read, notify | Battery percent |

The app's custom EQ (five signed band gains) uses `2DD12007`, which this Zone does not expose, so only
the three presets are supported.

Fan writes are untested against an attached visor; the characteristics and value ranges come from
the app code.
