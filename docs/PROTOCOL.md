# DyskLink Protocol v1

The service name and pairing code string still use `phonelink` so that older devices stay compatible.

## Device discovery
The Mac advertises the Bonjour service `_phonelink._tcp` on TCP port `47821`.
Android looks for that service in three ways:
1. NSD (mDNS).
2. Scanning port `47821` on the same /24 subnet, for networks that block multicast.
3. A manually entered IP address.

Android closes duplicate connections to the same device before sending `hello`.
The Mac only registers a connection after receiving `hello`, and that connection then replaces the old one.

## Heartbeat
Android sends `ping` every 25 seconds. With no data for 75 seconds, the connection counts as dead and Android
reconnects.

## Transport
TLS 1.2 or later with certificates on both sides. Certificates are self-signed, so the chain is not checked.
Trust comes from the fingerprint stored at pairing.

**Device ID** = SHA-256 of the DER certificate, in lowercase hex.
The ID always comes from the TLS certificate, never from message content.

## Message frame
`[length: UInt32 big-endian][UTF-8 JSON]`, at most 1 MiB per frame.
Receivers ignore unknown fields and message types.

```json
{ "type": "info", "info": { "batteryPercent": 80 } }
```

## Message types

| Type | Content | Condition |
|---|---|---|
| `hello` | `hello`: `name`, `platform`, `model`, `protocolVersion`, `paired` | First message from both sides |
| `pair.request` | - | Before pairing |
| `pair.accept` | - | The user confirmed the code |
| `pair.reject` | - | The user declined or the timeout expired |
| `unpair` | - | Any time |
| `info` | `info`: see `DeviceInfo` | Paired only |
| `ping`, `pong` | - | Any time |
| `clipboard` | `text`, at most 256 KiB; `key` asks for a receipt | Paired only |
| `clipboard.ack` | `key`, `error` if the text wasn't applied | Mac to phone, paired only |
| `media` | `media`: `play_pause`, `next`, `previous`, and phone to Mac only: `volume_up`, `volume_down`, `mute` | Paired only |
| `input` | `input`: `kind` (`move`, `click`, `scroll`, `text`, `key`), `dx`, `dy`, `button`, `text`, `key` | Phone to Mac, paired only |
| `commands.list` | `commands`: list of `id` and `name`, no script content | Mac to phone, paired only |
| `command.run` | `commandId` | Phone to Mac, paired only |
| `command.result` | `commandResult`: `id`, `exitCode`, `output` | Mac to phone, paired only |
| `file.offer` | `file`: `id`, `name`, `size` | Paired only |
| `file.chunk` | `file`: `id`, `data` (base64) | Paired only |
| `file.done` | `file`: `id`, `sha256` | Paired only |
| `file.cancel` | `file`: `id` | Paired only |
| `file.result` | `file`: `id`, `ok`, `error` | Paired only |
| `features` | `features`: list of active features (`notifications`, `sms`, `calls`, `contacts`, `files`, `screen`, `control`) | Phone to Mac, paired only |
| `notification.posted` | `notification`: `key`, `app`, `title`, `text`, `time`, `silent` | Phone to Mac, `notifications` feature |
| `notification.removed` | `key` | Phone to Mac, `notifications` feature |
| `notification.dismiss` | `key` | Mac to phone, `notifications` feature |
| `sms.list` | - | Mac to phone, `sms` feature |
| `sms.messages` | `sms`: list of `id`, `threadId`, `address`, `body`, `time`, `outgoing`; `more` | Phone to Mac, reply to `sms.list` |
| `sms.new` | `sms` | Phone to Mac, newly appeared messages |
| `sms.send` | `smsSend`: `id`, `address`, `body` (at most 2000 characters) | Mac to phone, `sms` feature |
| `sms.result` | `smsResult`: `id`, `ok`, `error` | Phone to Mac, after the carrier replies |
| `call` | `call`: `state` (`ringing`, `answered`, `outgoing`, `missed`, `ended`), `number`, `time` | Phone to Mac, `calls` feature |
| `contacts.list` | - | Mac to phone, `contacts` feature |
| `contacts` | `contacts`: list of `id`, `name`, `phones`; `more` | Phone to Mac |
| `fs.list` | `path`, relative to internal storage; `hidden: true` also lists names starting with a dot | Mac to phone, `files` feature |
| `fs.listing` | `path`, `entries`: list of `name`, `isDirectory`, `size`, `modified`; `more`, `error` | Phone to Mac |
| `fs.get` | `path`. The file arrives through `file.*`, failures through `fs.listing` with `error` | Mac to phone, `files` feature |

Messages other than `hello`, `pair.*`, `unpair`, `ping`, and `pong` are dropped if the device isn't paired.

`hello.paired` says whether the sender still considers the other side paired.
If the other side sends `paired: false`, this side removes its pairing too.

## Pairing
1. One side sends `pair.request`. Android does this automatically for a new Mac while its app is open, unless
   the user has declined or unpaired that Mac before.
2. Both sides show the same 6-digit code.
3. Each user compares the code, and that side then sends `pair.accept`.
4. Pairing finishes once the local user agrees **and** `pair.accept` from the other side has arrived.
5. The request is canceled after 60 seconds.

### Code formula
```text
input  = "phonelink-pair-v1:" + min(idA, idB) + ":" + max(idA, idB)
hash   = SHA-256(UTF-8 of input)
number = big-endian UInt32 of the first 4 bytes of hash
code   = number mod 1000000, written as 6 digits with leading zeros
```

An attacker in the middle uses a different certificate, so the codes on the two devices won't match.

## File transfer
Files are sent in chunks over the same connection. The receiver writes to a temporary file and only keeps it
if the size and SHA-256 match. File names are sanitized so they can't escape the destination folder.

## Screen and control
| Type | Content | Condition |
|---|---|---|
| `screen.request` | - | Mac to phone, `screen` feature. Only shows a notification on the phone |
| `screen.started` | `screen`: `width`, `height`. Sent again when the phone rotates | Phone to Mac |
| `screen.frame` | `video` (H.264 Annex B in base64), `keyFrame` | Phone to Mac |
| `screen.sync` | - | Mac to phone, requests a key frame for its own session |
| `screen.stop` | - | Mac to phone, for its own session only |
| `screen.stopped` | `error` | Phone to Mac |
| `control` | `control`: `kind`, `x`, `y`, `text`, `key` | Mac to phone, `control` feature |

Recording only starts after the user approves the Android dialog. No message can bypass it.
Key frames always carry SPS and PPS. If the network falls behind, the phone drops frames until the next key
frame. Frames above 760 KiB are dropped so they still fit in a 1 MiB frame.

`control.kind`: `down`, `drag`, `up`, `text`, `key`. `down`, `drag`, and `up` form one continuous touch at
`x`, `y`, and the phone lifts it after 10 seconds without news. `control.key` is limited to `backspace`,
`enter`, `left`, `right`, `back`, `home`, and `recents`. Coordinates range from 0 to 1. The phone sanitizes
invalid values and refuses all control while locked.

## Phone data
Every feature is off until the user turns it on from the phone. A feature is active when its switch is on and
its Android permission is granted. The phone checks both on every request and sends `features` whenever the
list changes. The Mac clears data for features that are no longer active, and drops data messages that arrive
for inactive features.

No message can change these choices from the Mac. Long lists are split into several messages under 512 KiB.
`more: true` means another page follows.

`fs.*` can't leave internal storage: paths are canonicalized first, so `..` and symlinks pointing outside are
refused. No message can change or delete files.

## Commands
The phone only sends IDs from the list created on the Mac. The Mac refuses unregistered IDs.
Keys in `input.key` are also limited by a fixed list on the Mac.

## DeviceInfo
All fields are optional: `batteryPercent`, `isCharging`, `network`, `storageFreeBytes`, `storageTotalBytes`,
`osVersion`, `model`, `carrier`, `cellType`, `signalLevel` (0 to 4), `wifiLevel` (0 to 4), `inputTrusted` (from
the Mac: Accessibility permission is on).
