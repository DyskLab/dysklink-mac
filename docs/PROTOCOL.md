# DyskLink Protocol v1

The service name and pairing code string still use `phonelink` so that older devices stay compatible.

## Device discovery
The Mac advertises the Bonjour service `_phonelink._tcp` on TCP port `47821`.
Android looks for that service in three ways:
1. NSD (mDNS).
2. Scanning port `47821` on the same /24 subnet, for networks that block multicast.
3. A manually entered IP address.

Since 0.2.0 the Mac's Bonjour TXT record carries `id` (its device ID) and `platform=macos`.
DyskLink for Windows and Linux advertises the same service on the same port, with `platform=windows` or
`platform=linux`, and plays the Mac's part: phones dial it, it shows the pairing code, and it accepts the clipboard,
files, notifications, calls, ringing, and status. Phones treat `macos`, `windows`, and `linux` as computers and any
other platform as a phone. With **Sync with other computers** on, it also browses for other computers and
connects to Macs and PCs the same way Macs connect to each other, with the same allow-list. Mac-only messages (screen, notch, charging, and so on) are only sent to `macos`.

Android closes duplicate connections to the same device before sending `hello`.
The Mac only registers a connection after receiving `hello`, and that connection then replaces the old one.
Only the first `hello` on a connection counts; later ones are ignored.

Once a device is paired, whether it's a phone or a computer, and which computer platform, comes from the platform
saved at pairing, not from later `hello` messages. A paired device whose `hello` (with `paired: true`) claims another
kind (phone ↔ computer, or another computer platform such as `windows` → `macos`) has its connection closed. A phone
may report another phone platform.

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
Receivers ignore unknown fields and message types. A receiver closes the connection on a larger frame, so senders
drop such a message instead of sending it (the Mac logs and drops it, and the connection stays up).

```json
{ "type": "info", "info": { "batteryPercent": 80 } }
```

### Binary frames (`bin1`)
Since 1.2, `hello.caps` lists optional features as strings; the only one so far is `"bin1"`. Receivers ignore
unknown fields, so older apps (1.1.x and before, on Mac, Android, Windows, and Linux) ignore `caps`, and unknown
entries in it are ignored too. A side sends binary frames only when **its own** hello listed `bin1` and the other
side's **first** hello did; before that hello arrives, and always with older apps, everything stays JSON. Someone in
the middle can only remove `bin1` (TLS protects the rest), which just falls back to JSON.

```text
[UInt32 BE: 0x80000000 | length][UInt16 BE: header length][header: UTF-8 JSON][raw payload]
```

- The top bit of the first word marks a binary frame; `length` is the rest of the word and counts everything after
  it (2 + header + payload), at most 1 MiB like a JSON frame. Older apps close the connection on such a word, which
  is why they never get one.
- The header is the usual envelope without its base64 field, for example `{"type":"macscreen.frame","keyFrame":true}`
  or `{"type":"file.chunk","file":{"id":"…"}}`. The payload is that field's raw bytes. Any base64 field still in the
  header is ignored. A missing `keyFrame` means false, so binary headers leave it out unless it's true.
- A receiver closes the connection on a malformed binary frame: `length` below 3 or over 1 MiB, a header length of 0
  or past `length`, a header that isn't a JSON message, or a frame cut short. (A JSON frame whose text doesn't parse
  is still only dropped.)
- Binary frames may carry any message type, but only these are sent that way, with the payload in place of:

| Type | Payload (was) |
|---|---|
| `macscreen.frame`, `screen.frame`, `camera.frame` | `video`: H.264 Annex B |
| `audio.frame` | `audio`: 16-bit PCM |
| `file.chunk` | `file.data`: the file bytes. `file.done` keeps the SHA-256 of all of them |

Raw media is a quarter smaller than base64 and costs no encoding. Everything else, including `file.offer` and
`file.done`, stays JSON. Live and file messages keep their own lanes and the file window works as before. A video
frame larger than 760 KiB is still dropped, since the same frame may have to go out as base64.

Fixed vector (Mac and Kotlin tests check both produce exactly these bytes): `file.chunk` id `abc` with bytes
`00 01 02 ff` is `8000002f 0029` + UTF-8 `{"type":"file.chunk","file":{"id":"abc"}}` + `000102ff`; `audio.frame` with
`01 00 ff ff` is `8000001c 0016` + `{"type":"audio.frame"}` + `0100ffff`.

## Message types

| Type | Content | Condition |
|---|---|---|
| `hello` | `hello`: `name`, `platform`, `model`, `protocolVersion`, `paired`, `appVersion` (0.2.0 and later), `caps` (1.2 and later, see Binary frames) | First message from both sides |
| `pair.request` | `pake` (`v`, `nonce`) | Before pairing |
| `pair.pake` | `pake` (`v`, `nonce`, `y`) | Showing side, after `pair.request` |
| `pair.accept` | `pake` (`v`, `y`, `confirm` from the typing side; `confirm` from the showing side) | The code was typed, or it checked out |
| `pair.reject` | `error` (`wrong-code`, `update-required`, or readable text) | The user declined, a check failed, or the timeout expired |
| `unpair` | - | Any time |
| `info` | `info`: see `DeviceInfo` | Paired only |
| `ping`, `pong` | - | Any time |
| `clipboard` | `text`, at most 262,144 UTF-16 code units; `key` asks for a receipt | Paired only |
| `clipboard.ack` | `key`, `error` if the text wasn't applied | Mac to phone, paired only |
| `media` | `media`: `play_pause`, `next`, `previous`, and phone to Mac only: `volume_up`, `volume_down`, `mute` | Paired only |
| `input` | `input`: `kind` (`move`, `click`, `scroll`, `text`, `key`, `shortcut`), `dx`, `dy`, `button`, `text`, `key` | Phone to Mac, paired only |
| `commands.list` | `commands`: list of `id` and `name`, no script content | Mac to phone, paired only |
| `command.run` | `commandId` | Phone to Mac, paired only |
| `command.result` | `commandResult`: `id`, `exitCode`, `output` | Mac to phone, paired only |
| `file.offer` | `file`: `id`, `name`, `size` | Paired only |
| `file.chunk` | `file`: `id`, `data` (base64; raw in a binary frame to a `bin1` peer) | Paired only |
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
Since protocol version 3, pairing uses CPace (draft-irtf-cfrg-cpace, the CPace255 suite: X25519, Elligator 2,
SHA-512), so a device in the middle gets at most one online guess of the 6-digit code per attempt. **T** is the
device that asks and types the code, **S** the device that shows it. All `pake` fields are in the normal envelope;
binary values are base64, and receivers ignore unknown fields.

1. T sends `pair.request` with `pake: {"v": 1, "nonce": nonceT}` (16 random bytes).
2. S shows a random 6-digit code, picks a random scalar `ya`, and answers `pair.pake` with
   `pake: {"v": 1, "nonce": nonceS, "y": Ya}` (16 random bytes, 32-byte point). It keeps `ya` while the code shows.
3. The user types the code on T. With a fresh scalar `yb` each try, T sends `pair.accept` with
   `pake: {"v": 1, "y": Yb, "confirm": confirmT}`.
4. S checks `confirmT` in constant time. Wrong (or a low-order `Yb`): `pair.reject` with `error: "wrong-code"`,
   counted by the limits below, and the same code can be typed again. Right: S saves the pairing and sends
   `pair.accept` with `pake: {"v": 1, "confirm": confirmS}`. T saves the pairing only if `confirmS` matches;
   otherwise it sends `pair.reject` and gives up.

```text
PRS  = UTF-8 of the 6-digit code
sid  = nonceT || nonceS
CI   = lv_cat("dysklink-pair-v3", fingerprint of T's certificate, fingerprint of S's certificate)
       (fingerprints as each side sees them on this TLS connection: lowercase hex SHA-256 of the DER, as ASCII)
G    = calculate_generator(SHA-512, PRS, CI, sid)       generator_string + Elligator 2, as in the draft
Ya   = X25519(ya, G)   Yb = X25519(yb, G)               S is CPace's A, T is B; ADa = ADb = empty
K    = X25519(ya, Yb) = X25519(yb, Ya)                  all zeros: abort
ISK  = SHA-512(lv_cat("CPace255_ISK", sid, K) || lv_cat(Ya, "") || lv_cat(Yb, ""))
confirmT = first 32 bytes of HMAC-SHA512(ISK, "dysklink-confirm-T")
confirmS = first 32 bytes of HMAC-SHA512(ISK, "dysklink-confirm-S")
```

A device in the middle has its own certificate on each leg, so CI differs on the two legs and it can't relay.
A second `pair.request` from the same device while its code shows keeps the code (and the wrong tries); with a new
nonce S answers a new `pair.pake` for that code. A new code always gets a new `ya` and `nonceS`.

Version 1 and 2 pairing are no longer accepted for new pairings, and there is no fallback. When the other side's
`hello.protocolVersion` is below 3, its `pair.request` has no valid `pake`, or its `pair.accept` has only the
version 2 `key`, no code is shown or checked: the answer is `pair.reject` with `error: "update-required"` and the
user sees "Update DyskLink on <name> to pair". Already paired devices are unaffected: trust still comes from the
fingerprint saved at pairing.

The limits below (wrong codes per device and in total, the 60-second timeout, and on the Mac one new prompt per
2 seconds) apply unchanged. When both ask at once, the device with the smaller ID shows the code.

### Version 1 (no longer accepted)
1. One side sent `pair.request`.
2. Both sides showed the same 6-digit code.
3. Each user compared the code, and that side then sent `pair.accept`.
4. Pairing finished once the local user agreed **and** `pair.accept` from the other side had arrived.
5. The request was canceled after 60 seconds.

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

Receivers take chunks of any size; the Mac sends 64 KiB of file data per chunk (192 KiB before 1.0.x). So that
input, sound, and video don't wait behind a file on the same connection, the Mac sends live messages ahead of queued
chunks, sends a `ping` after about every 128 KiB of file messages, and keeps at most 512 KiB of them unanswered by
`pong`. A device that doesn't answer within 3 seconds gets the rest without that limit.

## Screen and control
| Type | Content | Condition |
|---|---|---|
| `screen.request` | - | Mac to phone, `screen` feature. Only shows a notification on the phone |
| `screen.started` | `screen`: `width`, `height`. Sent again when the phone rotates | Phone to Mac |
| `screen.frame` | `video` (H.264 Annex B in base64, or raw in a binary frame), `keyFrame` | Phone to Mac |
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

A paired computer may only send `hello`, `pair.*`, `unpair`, `info`, `ping`, `pong`, `clipboard`, `clipboard.history`,
`ring`, `file.*`, and between Macs `remote.*`. Anything else from a computer is dropped, so it can't run commands.

A copied picture goes to paired computers as a file with `kind: "clipboard"` (PNG, up to 24 MB). The receiver puts it
on its clipboard instead of saving it, and doesn't list it as a transfer.

### One mouse and keyboard
Each Mac chooses which side of it a paired Mac sits on. A Mac accepts input only while **Let paired Macs use their
mouse and keyboard here** is on, which its `info.remoteControl` reports. When the pointer is pushed past the chosen
outer edge twice in a row, the Mac in use sends `remote.enter`, hides and holds its pointer, and forwards input as
`remote.input` until the pointer comes home. The other Mac posts the input as if its own mouse and keyboard were used.

| Type | `remote` | Direction |
|---|---|---|
| `remote.enter` | `edge` where the pointer appears, `at` 0–1 along it | Mac in use → other Mac |
| `remote.input` | `kind`: `move` (`dx`, `dy`), `down`/`up` (`button` 0 left, 1 right, 2+ other), `scroll` (`dx`, `dy` in pixels), `key` (`keyCode`, `keyDown`, `flags`), `flags` (`keyCode`, `flags`) | Mac in use → other Mac |
| `remote.leave` | `edge`, `at`: the pointer was pushed back past the edge facing the Mac in use | other Mac → Mac in use |
| `remote.exit` | none: control ended (Control-Option-Command, the setting turned off, or refused) | either way |

The other Mac lets go of held keys and buttons on `remote.exit`, `remote.leave`, when the connection drops, and when
either side unpairs. `remote.exit` is accepted even from a device that is no longer paired, since it only ends
control. Only a device paired as `macos` may send `remote.enter`, `remote.input`, and `remote.leave`.

The receiving Mac checks every number: key codes outside 0–127 and buttons outside 0–31 are dropped, `dx`/`dy`
are clamped to ±4000, and non-finite numbers drop the event. A Mac whose pointer is on another Mac refuses
`remote.enter` with `remote.exit`, and pointer events that DyskLink posted itself never cross an edge, so control
can't loop between two Macs.

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
`ping`/`pong`, and `file.*`, plus the screen and camera messages below (since 1.3), the notification, call,
push-to-talk, and sound messages (since 1.4), the link, music, monitor, quiet, and locate messages (since 1.5),
and the SMS, move, and photo backup messages (since 1.6), which pass only the per-phone switches. Everything else from
a phone is dropped, so Mac-only messages (`sms.*`, `contacts.*`, `fs.*`, `input`, ...) stay Mac-only.

### Another phone's screen and camera (1.3)

A phone lists `p2p-screen` and `p2p-camera` in `hello.caps`. The other phone shows View screen and Camera only for a
peer that lists them, so phones on 1.2.0 and older (`caps` of `["bin1"]` or none) never see the buttons. Computers
never list them, and the desktop apps keep sending `["bin1"]`.

The phone being viewed or used (B) keeps a switch per paired phone (A): view the screen, control it, use the camera.
All start off; unpairing clears them. Viewing and the camera have three states: never asked, allowed, refused.

| Type | Content | Direction | Passes on B when |
|---|---|---|---|
| `screen.request` | - | A to B | Always, unless refused: B only shows a notification. Never asked: tapping it asks "Allow A to view this screen?" (Allow, Not now, Never) before Android's own recording dialog, which asks every session. Refused: B answers `screen.stopped` with `error` |
| `screen.sync` | - | A to B | Viewing allowed |
| `screen.stop` | - | A to B | Always; it only ends A's own session |
| `control` | `control` as from a Mac (`down`, `drag`, `up`, `key` `back`/`home`/`recents`, ...) | A to B | Viewing and control allowed, B's screen is shared with A now, and DyskLink's Accessibility service runs on B. Otherwise dropped |
| `screen.started` | `screen`, and `canControl` (whether A's taps go through) | B to A | Sent again when B turns, or a switch or Accessibility changes |
| `camera.request` | - | A to B | Always, unless refused: B shows a notification, and the camera starts only after a tap (Android doesn't allow it from the background). Never asked: the tap asks "Allow A to use the camera?" first |
| `camera.sync` | - | A to B | Camera allowed |
| `camera.control` | `text`: `switch`, `torch`, `record.start`, `record.stop` | A to B | Camera allowed, and only for A's own stream |
| `camera.zoom` | `zoom` from 1 to `maxZoom` | A to B | Camera allowed |
| `camera.shutter` | `key`: a name for this photo | A to B | Camera allowed. Answered with `camera.shot` |
| `camera.stop` | - | A to B | Always; it only ends A's own stream |
| `camera.started` | as for the Mac, plus `cameraState`: `zoom`, `maxZoom`, `flash`, `torch`, `recording`, `stills` | B to A | Sent again when any of these change |
| `camera.shot` | `key`, `text` (`photo` or `video`), `file.name`, or `error` | B to A | |

Messages from B to A (`screen.started`/`frame`/`stopped`, `camera.started`/`frame`/`stopped`/`shot`) are taken only
while A has asked B for that one and hasn't stopped; anything else is dropped. A `*.stopped` ends it until A asks again.

- One viewer at a time: a second phone or Mac asking while B's camera is in use gets `camera.stopped` with `error` at
  once; for the screen, `screen.stopped` with `error` comes when its request is tapped on B.
- B shows "Being viewed by A" or "Camera used by A" with Stop while it runs. It ends when either side stops, when the
  connection drops (no waiting for it to come back, unlike with a Mac), when A's viewer leaves the screen, when Android
  ends the recording, or when B turns the switch off.
- `camera.shutter`: B takes a full-size JPEG on a second output at the camera's largest JPEG size, while the video goes
  on, saves it in Pictures/DyskLink, answers `camera.shot`, then sends the photo with the usual `file.*` messages.
  At most 3 photos wait at once; more are answered with `error`. The self-timer runs on A.
- `record.start`/`record.stop`: B records the stream it already encodes (no sound, up to 10 minutes) into
  Movies/DyskLink, then answers `camera.shot` with `text: "video"` and sends the file.
- Frame sizes and the 1 MiB frame limit are unchanged; video is the same H.264 as for the Mac, binary to `bin1` peers.

### Notifications, calls, push-to-talk, and sound between phones (1.4)

A phone lists `p2p-notify`, `p2p-talk`, and `p2p-sound` in `hello.caps`; the other phone shows Notifications, Hold to
talk, and Play sound there only for a peer that lists them, and tells the user to update a peer that doesn't. B is the
phone whose notifications are sent, or that plays the voice or sound; A is the other one. B's switches for A (kept with
the screen and camera ones, cleared on unpair): send notifications (off), the apps left out of them, send calls (off),
talk to this phone and play sound from A (never asked, allowed, refused).

| Type | Content | Direction | Passes when |
|---|---|---|---|
| `notification.posted` | `notification` as for a Mac, plus `reply` and `markRead` (B's notification has those actions) | B to A | Sent only while B's switch for A is on, never for a left-out app; the ones showing go with `silent: true` when A connects or the switch turns on |
| `notification.removed` | `key` | B to A | For a notification B sent A |
| `notification.cleared` | - | B to A | The switch went off or the left-out apps changed; A drops all from B (B then resends what it may) |
| `call` | `call` as for a Mac | B to A | B's call switch for A is on (and Android's phone permission) |
| `notification.dismiss` | `key` | A to B | B's switch is on and B sent A that key; otherwise dropped |
| `notification.read` | `key` | A to B | As for dismiss. B presses the notification's "mark as read" action |
| `notification.reply` | `key`, `text` (at most 2000 characters) | A to B | As for dismiss. B fills the notification's reply action (RemoteInput). Always answered |
| `notification.result` | `key`, `error` | B to A | Answer to `notification.reply`, with `error` when refused or failed |
| `talk.start` | `audioRate`, `audioChannels` (16000, 1) | A to B | Allowed and no other phone is talking to B. Never asked: refused, and B asks "Allow A to talk to this phone?" (Allow, Not now, Never) |
| `talk.frame` | 16-bit PCM in `audio`, binary to `bin1` peers; 40 ms each | A to B | After a `talk.start` B took |
| `talk.stop` | - | A to B | Ends A's own voice |
| `talk.stopped` | `error` | B to A | Refused (with why), or stopped on B |
| `audio.started`, `audio.frame`, `audio.stopped` | as from a phone to a Mac | A to B | Like `talk.*`, by B's "Play sound from A" switch; one phone's sound at a time |
| `audio.stop` | `error` | B to A | Refused (with why), or stopped on B; A stops recording |

- B's notifications follow the Mac's rules: none an app marks secret, no ongoing ones, none of DyskLink's own. One-time
  codes go as text, as to a Mac. A shows them as notifications under a channel group per phone (private on the lock
  screen), and in a list on B's page, only while B is connected: removed on B or a dropped connection removes them on A.
- A ringing call shows on A with Silence, which only quiets A. There is no reject or answer from A: B has no call control.
- Push-to-talk is half-duplex: A records the microphone while Talk is held (a microphone foreground service), B plays it
  with a short queue and a beep at start and end, and shows "A is talking" with Stop.
- Sound uses B's player for a Mac's sound (the same queue and cushion after a gap), and A's recording of what it plays
  (Android 10 and newer, the same Android prompt as for a Mac). Either side can stop it; a dropped connection ends both
  voice and sound on both sides at once, and turning B's switch off ends them too.

### Links, music remote, family monitor, quiet mode, and Locate (1.5)

A phone lists `p2p-open`, `p2p-media`, `p2p-monitor`, `p2p-quiet`, and `p2p-locate` in `hello.caps`; the other phone
shows the matching cards only for a peer that lists them, and tells the user to update a peer that doesn't. A asks, B
carries it out. B keeps a switch per kind for A (with the others, cleared on unpair): accept links, control music,
share screen time, silence this phone, share location. Each is never asked, allowed, or refused. A request B doesn't
carry out is answered at once with the answer type and `error` saying why; never asked, B also asks its user once
(Allow, Not now, Never). A takes an answer only for a request it sent, once each, within 20 s (60 s for Locate); any
other answer is dropped.

| Type | Content | Direction | Passes on B when |
|---|---|---|---|
| `link.open` | `text`: the link, `key` | A to B | Links allowed. B checks the link again (below) and shows "A sent a link" with Open |
| `link.result` | `key`, `text` (the link as shown), or `error` | B to A | |
| `media.remote` | `media`: `play_pause`, `next`, `previous`, `volume_up`, `volume_down`, or `state` | A to B | Music allowed. Anything else is answered with `error` |
| `media.state` | `nowPlaying`: `title`, `artist`, `app`, `playing`, `art` (base64 JPEG, at most 128 px), `volume`, `maxVolume`, `note`; or `error` | B to A | Answer to each `media.remote` |
| `monitor.request` | - | A to B | Screen time allowed |
| `monitor.report` | `usage` as `usage` for a Mac, or `error` (no Usage access) | B to A | |
| `quiet.set` | `quiet`: `mode` (`silent`, `vibrate`, `normal`, `dnd.on`, `dnd.off`), and `minutes` (1 to 720) or `untilMorning` | A to B | Quiet allowed |
| `quiet.result` | `quiet` as set, with `until` (ms since 1970) when it goes back by itself; or `error` | B to A | |
| `locate.request` | - | A to B | Location allowed |
| `locate.result` | `location`: `lat`, `lon`, `accuracy` (m), `time` (ms since 1970), `provider`; or `error` | B to A | |

- Links: only `http`/`https` (with a host, no user info), `geo:` with valid coordinates, and phone numbers (`tel:` or
  bare digits with `+ - ( ) .` and spaces; no `*` or `#`). Everything else (`intent:`, `file:`, `content:`,
  `javascript:`, `data:`, `sms:`, `mailto:`, ...) is refused by both phones. Nothing opens by itself: Open starts the
  browser (`BROWSABLE`), the maps app, or the dialer with the number filled in (`ACTION_DIAL`, never a call). A sends
  them from its share sheet ("Open on B") or the "Send link…" field on B's page.
- Music: B uses the active media session (through DyskLink's notification listener; without notification access the
  buttons still go as media keys and `note` says why there's no title). Volume is the music stream, without a panel on B.
  A asks for `state` every 3 s while the card shows, only after B answered once.
- Monitor: B's battery comes in `info` as before and needs no switch. A's alerts (kept on A, cleared on unpair): low at
  10-30 % (15 % by default), once until B charges above it or rises 5 points over it; full at 100 % while charging,
  once until unplugged.
- Quiet: `until` is worked out on B, in B's time zone (`untilMorning` is the next 07:00 there). Silent and Do Not
  Disturb need Do Not Disturb access on B; vibrate and normal are tried without it. B keeps what was on before the
  first change and shows "A turned on Do Not Disturb" (or the mode) with Undo, which puts it back, as does the end time.
- Locate: B answers with a current fix (the platform fused provider on Android 12+, else GPS or network) within 12 s,
  else the last known one. B needs the location permission while in use; never background location. While some phone
  may ask, B's DyskLink service adds the `location` foreground type the next time the app is on screen; until then
  Android may give nothing, and the answer says "Location unavailable while DyskLink is in the background on B".
- Ring + flash: `ring` `start` with `text: "flash"` also blinks B's back torch until the ring stops. Older phones
  ignore `text` and only ring.

### SMS through another phone, moving to a new phone, and photo backup (1.6)

A phone lists `p2p-sms`, `p2p-move`, and `p2p-backup` in `hello.caps`; the other phone shows SMS, Move here, and the
photo backup card only for a peer that lists them, and tells the user to update a peer that doesn't. B keeps three
more switches for A (never asked, allowed, refused; cleared on unpair): read and send SMS, accept a phone move, accept
photo backup. Never asked, B refuses with `error` and asks its user once (Allow, Not now, Never).

| Type | Content | Direction | Passes on B when |
|---|---|---|---|
| `psms.list` | `key`; `smsThread` for one thread | A to B | SMS allowed, and Android's SMS permission on B |
| `psms.listing` | `key`, `smsThread`, `sms` (the newest message of each thread, at most 100; or the thread's last 200), or `error` | B to A | |
| `psms.send` | `smsSend`: `id`, `address`, `body` (at most 2000 characters) | A to B | SMS allowed, at most 10 a minute from A |
| `psms.result` | `smsResult`: `id`, `ok`, `error` | B to A | Answer to each `psms.send`, once the carrier took it or refused it |
| `psms.watch` | `key` | A to B | SMS allowed. B then sends new SMS while connected |
| `psms.watching` | `key`, or `error`; without `key`, B stopped (the switch went off) | B to A | |
| `psms.unwatch` | - | A to B | Always; it only stops what A gets |
| `psms.new` | `sms`: up to 20 new messages | B to A | Only to a phone that watches and is still allowed |
| `move.request` | `key`, `move`: `id`, `contacts`, `photos`, `files`, `bytes` | A (old) to B (new) | Move allowed, and `bytes` leaves at least 1 GB free |
| `move.answer` | `key`, `move`, `info.storageFreeBytes`; or `error` (and `file.reason: "low-space"`) | B to A | |
| `move.done` | `move` with `sent`, `skipped`, `failed`, `contactsFile` | A to B | Move allowed. B shows a summary with Import contacts |

- SMS: B's `sms.*` for a Mac are unchanged and never pass between phones. `address` is digits with `+ - ( ) .` and
  spaces only (no `*` or `#`, so no USSD). B shows "A sent an SMS to <number> using this phone" for each one sent,
  and keeps a log of every send and refused send on A's page (kept after unpairing). A takes `psms.listing` and
  `psms.watching` only with a `key` it sent within 20 s, `psms.result` only for an `id` it sent within 2 min, and
  `psms.new` only while B took its watch; anything else is dropped. A opens the SMS screen only after its own screen
  lock (fingerprint, face, or PIN) is confirmed, once per session: the session ends after 5 minutes without use, when
  the screen turns off, or when DyskLink leaves the screen. "Show new SMS here" (kept on A) sends `psms.watch` again
  each time B connects; new SMS show as notifications on A, private on the lock screen. B sends with its default SMS
  SIM. No MMS.
- Files of a move and photo backup use the usual `file.*` messages, with `file.kind`: `photo` (backup),
  `move.contacts`, `move.media`, or `move.file`. A plain `file.offer` without one of these kinds goes to Downloads as
  before, without a switch. `file.offer` may carry `folder` (a `/`-separated path, made safe by the receiver: no
  `..`, at most 6 levels) and `sha256`. B refuses with `file.result` `ok: false`, `error`, and `reason`: `ask` (never
  asked), `off` (refused), or `low-space` (less than 1 GB would be left; B shows a notification). A copy B already has
  (same folder, name, size, and SHA-256, still on B) is answered at once with `ok: true, skipped: true`, and A stops
  sending it.
- Where B keeps them: photos and videos (`photo`, `move.media`) in Pictures/DyskLink/<A's name>/, everything else in
  Download/DyskLink/<A's name>/<folder>/. B never writes contacts: `move.done` names the .vcf (vCard 3.0), and Import
  contacts opens it with the system Contacts app.
- Moving (on the old phone): pick contacts (read with the contacts permission, sent as one .vcf), photos and videos
  (all, or a date range), and folders (the system folder picker). A sends `move.request`, then one file at a time,
  then `move.done`. Its progress is kept on disk: pause cancels the file being sent and resumes with it; a dropped
  connection waits and asks again when B is back; a file that fails three times is left out. Refusals pause the move
  with why.
- Photo backup (on the phone with the photos): as photo sync to a Mac, each target with its own position and its own
  options (Include videos, Only on Wi-Fi, Only while charging, earlier photos). To a phone, each offer carries
  `sha256`. On `low-space`, A turns backup to that phone off and shows a notification.

## Pairing, version 2 (no longer accepted)

Version 2 typed the code: the device that received `pair.request` showed a random code, and the requesting device
sent `pair.accept` with `key = hex(SHA-256("dysklink-pair-v2:<code>:<smaller id>:<larger id>"))`. A device in the
middle could take that hash and try all 10^6 codes offline, so version 3 replaced it with CPace (see Pairing above).
New apps answer this `key` with `pair.reject` `error = "update-required"`.

Guessing is limited on the showing device (the Mac since 1.0.x), and the same limits apply to version 3:
- Wrong codes count per device across prompts, so a new `pair.request` doesn't give five fresh tries.
- After 5 wrong codes that device waits 60 seconds, then twice as long after each further 5, up to 1 hour. During
  the wait its `pair.request` gets `pair.reject` with `error` saying how long to wait. A right code clears its count.
- 15 wrong codes from any devices within 10 minutes close pairing for everyone for 10 minutes.
- While a code is showing, another `pair.request` from the same device doesn't make a new code, and requests from
  one device closer than 2 seconds apart are dropped without an answer.

When both ask at once, the device with the smaller ID shows the code. Paired devices reconnect without a code.

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
| `macscreen.frame` | `video` (H.264 Annex B in base64, or raw in a binary frame), `keyFrame` | Mac to phone |
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
`file.result` says the Mac saved it. Since 1.6 a paired phone that lists `p2p-backup` can be a target too (see "SMS through another
phone, moving to a new phone, and photo backup"), and "Only while charging" waits until the phone is plugged in.

## Phone camera on the Mac

| Type | Content | Direction |
|---|---|---|
| `camera.request` | - | Mac to phone. The phone shows a notification; the camera starts only after a tap |
| `camera.started` | `screen` (encoded size), `text` (`front`/`back`), `rotation` (clockwise degrees to turn upright) | Phone to Mac, sent again when the lens or the way the phone is held changes |
| `camera.frame` | `video` (H.264 Annex B in base64, or raw in a binary frame), `keyFrame` | Phone to Mac |
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
The Mac gives fingers 0–7 to its keys (joysticks, taps, skills, swipes), 8 to the click spot and 9 to the mouse or
look finger. Swipes and combos are plain `tdown`, `tmove` about every 16 ms, and `tup` on one finger; auto-fire and
combos may lift and press the same finger again within tens of milliseconds. Nothing new is sent.

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

Sound is 16-bit little-endian interleaved PCM, 48 kHz stereo, in 40 ms chunks (7,680 bytes), raw in a binary frame
to a `bin1` peer and as base64 to anyone else. Either side can send its sound; the receiver keeps a short queue and
drops chunks when it falls behind.

Silence: toward a `bin1` peer only, a sender stops sending chunks that are digitally silent (no sample above ±8, about
-72 dBFS) once 200 ms of them (5 chunks) have gone out, and starts again with the first chunk that isn't. There is no
marker or keepalive: a receiver plays silence by itself when its queue runs dry, and when a chunk comes after its
queue ran dry (a gap of more than about 200 ms on Android) it first plays 40 ms of silence (beside a screen) or 80 ms,
the same head start it takes when sound starts, so the sound that comes back doesn't stutter or drift. Older
receivers keep getting every chunk, silence included.

| Type | Fields | Notes |
|---|---|---|
| `audio.listen` | - | Phone to Mac. Refused with `audio.stopped` and `error` unless "Let phones hear this Mac" is on |
| `audio.started` | `audioRate`, `audioChannels` | From the side that sends sound, before its chunks |
| `audio.frame` | `audio` (or the binary payload) | One chunk. The Mac keeps at most 6 unconfirmed chunks per phone in flight |
| `audio.stop` | - | Asks the other side to stop sending its sound. A phone screen goes on without sound |
| `audio.stopped` | `error` (optional) | The sender stopped |
