# DyskLink Protocol v1

The service name and pairing code string still use `phonelink` so that older devices stay compatible.

## Device discovery
The Mac advertises the Bonjour service `_phonelink._tcp` on TCP port `47821`.
Android looks for that service in three ways:
1. NSD (mDNS).
2. Scanning port `47821` on the same /24 subnet, for networks that block multicast.
3. A manually entered IP address.

Since 0.2.0 the Mac's Bonjour TXT record carries `id` (its device ID) and `platform=macos`.

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
| `hello` | `hello`: `name`, `platform`, `model`, `protocolVersion`, `paired`, `appVersion` (0.2.0 and later) | First message from both sides |
| `pair.request` | - | Before pairing |
| `pair.accept` | - | The user confirmed the code |
| `pair.reject` | - | The user declined or the timeout expired |
| `unpair` | - | Any time |
| `info` | `info`: see `DeviceInfo` | Paired only |
| `ping`, `pong` | - | Any time |
| `clipboard` | `text`, at most 256 KiB; `key` asks for a receipt | Paired only |
| `clipboard.ack` | `key`, `error` if the text wasn't applied | Mac to phone, paired only |
| `media` | `media`: `play_pause`, `next`, `previous`, and phone to Mac only: `volume_up`, `volume_down`, `mute` | Paired only |
| `input` | `input`: `kind` (`move`, `click`, `scroll`, `text`, `key`, `shortcut`), `dx`, `dy`, `button`, `text`, `key` | Phone to Mac, paired only |
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
Keys in `input.key` are also limited by a fixed list on the Mac. A `shortcut` sends `key` as modifiers and one key joined with `+`, such as `cmd+shift+4`: modifiers are `cmd`, `shift`, `opt`/`alt`, `ctrl`, and `fn`, and the key is a letter, digit, punctuation key, `f1` to `f12`, `return`, `tab`, `space`, `delete`, `escape`, an arrow, `home`, `end`, `pageup`, or `pagedown`, by US key position. Anything else is ignored. Older Macs ignore `shortcut`.

## Notch: Todo list, water, and Pomodoro
The Mac keeps this data. The phone shows it and asks for changes, and the Mac then sends the new state to every
paired phone.

| Type | Content | Condition |
|---|---|---|
| `notch.state` | `notch`: `todos` (list of `id`, `title`, `done`), `water` (`totalMl`, `goalMl`, `glassMl`), `focus` (`phase`, `session`, `sessions`, `running`, `remainingMs`, `lengthMs`) | Mac to phone, paired only. Sent after pairing or reconnecting, and whenever something changes |
| `notch.action` | `notchAction`: `kind`, `id`, `text` | Phone to Mac, paired only |

`notchAction.kind`: `todo.add` (`text`), `todo.toggle` (`id`), `todo.delete` (`id`), `todo.rename` (`id`, `text`),
`water.drink`, `water.undo`, `focus.toggle`, and `focus.reset`. Titles are cut to one line of 80 characters.
`focus.phase` is `focus`, `shortBreak`, or `longBreak`. `remainingMs` is the time left when the message was sent,
so the phone counts down from when it arrives and the two clocks don't need to agree.

## Find device
| Type | Content | Condition |
|---|---|---|
| `ring` | `ring`: `start`, `stop`, or `stopped` | Either way, paired only |

`start` makes the other side play a loud sound for up to 30 seconds. The phone uses the alarm stream, so silent
mode doesn't mute it. `stop` ends it early, and the ringing side sends `stopped` when the user ends it there.

## Mac actions
| Type | Content | Condition |
|---|---|---|
| `mac.action` | `macAction`: `lock`, `awake.start`, or `awake.stop` | Phone to Mac, paired only |

These are fixed actions for the phone's Quick Settings tiles and widget. `lock` locks the Mac's screen. The two
`awake` actions only work while Keep Awake is turned on in Advanced, and use the length chosen there. The Mac
replies with `info`, whose `keepAwake` is `active`, `idle`, or `unavailable`.

## Mac to Mac
With **Other Macs** turned on, a Mac browses `_phonelink._tcp` and connects to each Mac whose TXT `id` is larger
than its own, so two Macs only ever hold one connection. The connecting Mac uses the same TLS setup as a phone, sends
`hello` with `platform: "macos"`, and pairs with the same 6-digit code. A Mac with Other Macs turned off closes
connections whose `hello.platform` is `macos`.

A paired Mac may only send `hello`, `pair.*`, `unpair`, `info`, `ping`, `pong`, `clipboard`, `clipboard.history`,
`ring`, and `file.*`. Anything else from a Mac is dropped, so another Mac can't send input or run commands.

| Type | Content | Condition |
|---|---|---|
| `clipboard.history` | `clips`: up to 500 of `text` and `time` (ms since 1970), newest first, under about 800 KB | Mac to Mac, sent once after connecting when both share copies |

Live copies use the normal `clipboard` message. Images aren't synced.

## DeviceInfo
All fields are optional: `batteryPercent`, `isCharging`, `network`, `storageFreeBytes`, `storageTotalBytes`,
`osVersion`, `model`, `carrier`, `cellType`, `signalLevel` (0 to 4), `wifiLevel` (0 to 4), `inputTrusted` (from
the Mac: Accessibility permission is on), `keepAwake` (from the Mac, see Mac actions).

## Terminal

A phone can open a shell on the Mac when the Mac has **Terminal from the phone** turned on (off by default).
All messages carry `terminal` = `{id, data?, cols?, rows?, error?, exitCode?}`; `data` is base64 bytes.

| Type | From | Meaning |
|---|---|---|
| `terminal.open` | phone | Start a login shell with `cols` × `rows`. |
| `terminal.opened` | Mac | The shell runs. |
| `terminal.input` | phone | Typed bytes, xterm encoding (Return is `\r`). |
| `terminal.output` | Mac | Bytes the shell printed. |
| `terminal.resize` | phone | New `cols` × `rows`. |
| `terminal.close` | phone | Hang up (SIGHUP, then SIGKILL after 2 s). |
| `terminal.closed` | Mac | Ended, with `exitCode`, or `error` when refused or ended on the Mac. |

The Mac allows 4 sessions per phone, ends them all when the phone disconnects, and shows a notification for each one opened.
The phone asks for fingerprint, face, or the screen lock before each session.

## Phone to phone

Phones also listen on TCP 47822 (TLS, client certificate required, so the ID is known both ways) and advertise
`_phonelink._tcp` with TXT `id=<device id>` and `platform=android`. Macs only dial `platform=macos`, so they ignore these.
Between two phones only the one with the smaller ID dials. Pairing is the same 6-digit code.

Allowed between phones: `hello`, `pair.*`, `unpair`, `info`, `clipboard` (the receiver answers `clipboard.ack`), `ring`,
`ping`/`pong`, and `file.*`. Everything else from a phone is dropped.

## Pairing, version 2

From protocol version 2 the code is typed, not compared.

1. The device that wants to pair sends `pair.request`.
2. The device that receives it shows a random 6-digit code.
3. The code is typed on the requesting device, which sends `pair.accept` with
   `key = hex(SHA-256("dysklink-pair-v2:<code>:<smaller id>:<larger id>"))`. The IDs are the certificate
   fingerprints each side sees, so a device in the middle can't reuse the code.
4. When the key matches, the showing device saves the pairing and answers `pair.accept`. The typing device saves it then.
   A wrong key gets `pair.reject` with `error = "wrong-code"`, and the code can be typed again. After 5 wrong tries the
   showing device sends a plain `pair.reject`.

When both ask at once, the device with the smaller ID shows the code. A device whose `hello.protocolVersion` is below 2
can't pair this way and is asked to update. Paired devices reconnect without a code, as before.

## Codes, quick note

- One-time codes are found on the Mac in `notification.posted` and `sms.new`. Nothing new is sent.
- `notch.state` has `note` and `noteTime` (milliseconds since 1970). A phone changes the note with `notch.action`
  `{kind: "note.set", text}`. The Mac keeps it and sends the new state back. Up to 4000 characters.

- `notch.state` also has `music` (`title`, `artist`, `playing`) with what plays on the Mac, for the phone's media widget.

## Wake-on-LAN

`info` from the Mac has `wakeMacs` (hardware addresses: the one in use when the app can read it, and the card's own),
`wakeBroadcast` (the network's broadcast address), and `wakeEnabled` ("Wake for network access" on power). The phone keeps
them with the pairing and sends magic packets (6 × 0xFF, then the address 16 times) to both broadcast addresses on UDP
ports 9 and 7.

## This Mac's screen on a phone

| Type | Content | Direction |
|---|---|---|
| `macscreen.start` | - | Phone to Mac. Refused with `macscreen.stopped` unless "View this screen from the phone" is on and Screen Recording is allowed |
| `macscreen.started` | `screen`: `width`, `height` (even, longer side up to 1600), `text`: display name | Mac to phone |
| `macscreen.frame` | `video` (H.264 Annex B in base64), `keyFrame` | Mac to phone |
| `macscreen.sync` | - | Phone to Mac, asks for a key frame |
| `macscreen.pointer` | `control`: `kind` (`move`, `down`, `drag`, `up`, `click`, `double`, `right`), `x`, `y` from 0 to 1 | Phone to Mac, needs Accessibility |
| `macscreen.stop` / `macscreen.stopped` | `error` on stopped | Either way |

Typing, keys, and scrolling use the usual `input` messages. Key frames carry SPS and PPS. When more than three frames
wait for the network, the Mac drops frames until the next key frame. Raw frames over 760 KiB are dropped. Only paired
phones can start it, and the Mac shows a notification while its screen is viewed.

## Photo sync

Photos use the usual file messages. A `file.offer` with `file.kind = "photo"` is saved in
`~/Pictures/DyskLink/<phone name>/` instead of Downloads. Older Macs ignore `kind` and save to Downloads.
The phone sends photos added after sync was turned on, oldest first, one at a time, and moves on only after
`file.result` says the Mac saved it.

## Phone camera on the Mac

| Type | Content | Direction |
|---|---|---|
| `camera.request` | - | Mac to phone. The phone shows a notification; the camera starts only after a tap |
| `camera.started` | `screen` (encoded size), `text` (`front`/`back`), `rotation` (clockwise degrees to turn upright) | Phone to Mac, sent again when the lens or the way the phone is held changes |
| `camera.frame` | `video` (H.264 Annex B in base64), `keyFrame` | Phone to Mac |
| `camera.sync` | - | Mac to phone, asks for a key frame |
| `camera.control` | `text`: `switch` or `torch` | Mac to phone, only for its own stream |
| `camera.stop` / `camera.stopped` | `error` on stopped | Either way |

## USB

No new messages. With USB debugging on, the Mac runs `adb reverse tcp:47823 tcp:47821` for each authorized phone.
The phone keeps trying `127.0.0.1:47823`; a connection there is the same TLS connection as over Wi-Fi. When it reaches
a Mac that is already connected over Wi-Fi, the phone closes the Wi-Fi connection and keeps the USB one, and the Mac
replaces the old session as it does for any newer hello. The Mac sees USB sessions as coming from a loopback address.

## Game keys (several fingers)

`control` with `kind` `tdown`, `tmove`, or `tup`, `x` and `y` from 0 to 1, and `key` holding the finger number from
0 to 9. Fingers move together, so a joystick can be held while other keys tap. The Mac repeats held fingers with
`tmove` every 1.5 seconds; the phone lifts all fingers after 5 seconds without any. Plain `down`/`drag`/`up` lift them.

## Phone as an extra display

`macscreen.start` with `text: "extend"` and `screen` (wanted size in points, landscape). The Mac makes a virtual
display with the phone's shape, landscape or portrait, with the short side at least 600 points so it can be sharp
(2×). Asking again with another size (the phone turned) replaces the display, and streams that display with the
usual `macscreen.*` messages. Stopping removes the display.

## Phone gallery

Needs the `gallery` feature on the phone.

| Type | Fields | Notes |
|---|---|---|
| `gallery.list` | `offset` | Mac to phone. Asks for the next page, newest first |
| `gallery` | `gallery`: items with `id`, `name`, `date` (ms), `size`, `video`, `durationMs`, `width`, `height`, `thumb` (base64 JPEG, 256 px); `offset`; `more`; `galleryEnd` | Phone to Mac. 60 items per request, split into frames under 512 KB |
| `gallery.get` | `galleryId` | Mac to phone. The phone sends the original as a file offer with kind `gallery` |

## Sound sharing

Sound is 16-bit little-endian interleaved PCM, 48 kHz stereo, in 40 ms chunks (7,680 bytes) sent as base64.
Either side can send its sound; the receiver keeps a short queue and drops chunks when it falls behind.

| Type | Fields | Notes |
|---|---|---|
| `audio.listen` | - | Phone to Mac. Refused with `audio.stopped` and `error` unless "Let phones hear this Mac" is on |
| `audio.started` | `audioRate`, `audioChannels` | From the side that sends sound, before its chunks |
| `audio.frame` | `audio` | One chunk. The Mac keeps at most 6 unconfirmed chunks per phone in flight |
| `audio.stop` | - | Asks the other side to stop sending its sound. A phone screen goes on without sound |
| `audio.stopped` | `error` (optional) | The sender stopped |
