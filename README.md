<p align="center">
  <img src="docs/icon.png" width="88" alt="DyskLink">
</p>

<h1 align="center">DyskLink for Mac</h1>

<p align="center">Connects your Mac and Android phone over local Wi-Fi, with no cloud and no account.</p>

<p align="center">
  <a href="https://github.com/DyskLab/dysklink-mac/releases/latest"><img src="https://img.shields.io/github/v/release/DyskLab/dysklink-mac?include_prereleases" alt="Latest release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/DyskLab/dysklink-mac" alt="MIT License"></a>
  <a href="https://dysklab.fanny.dev"><img src="https://img.shields.io/badge/part%20of-DyskLab-2DD4A7" alt="Part of DyskLab"></a>
  <a href="https://buymeacoffee.com/fannydevz"><img src="https://img.shields.io/badge/Buy%20Me%20a%20Coffee-support-FFDD00?logo=buymeacoffee&logoColor=000" alt="Buy Me a Coffee"></a>
</p>

![Phone notifications on the Mac](docs/screenshots/02-notifications.png)

DyskLink also adds a set of optional tools to the Mac, each off until you turn it on, and connects to other Macs
and to Windows and Linux PCs running [DyskLink for Windows and Linux](https://github.com/DyskLab/dysklink-desktop).

**This is the Mac app. The phone app is [DyskLink for Android](https://github.com/DyskLab/dysklink-android).**
You need both to use the phone features. The Advanced tools work on the Mac alone.

> DyskLink is still young, so expect rough edges.

## Download
You need macOS 15 or later on Apple Silicon, and DyskLink for Android 1.5.0 on the phone for everything in this
version. Pairing a new device needs 1.2.0 or later on both sides. Which features work on which Mac is in
[COMPATIBILITY.md](COMPATIBILITY.md) (in Indonesian).

1. Download `DyskLink-mac-arm64.zip` from the [latest release](https://github.com/DyskLab/dysklink-mac/releases/latest),
   unzip it, and move **DyskLink** to Applications.
2. The app isn't notarized, so macOS blocks the first launch. Open **System Settings > Privacy & Security** and choose
   **Open Anyway**.
3. [Install the Android app](https://github.com/DyskLab/dysklink-android#download) and open it on the same network.

This download uses a self-signed certificate, not one from Apple. To run on Intel,
[build it from source](#build-and-run).

To update, quit DyskLink, replace it in Applications, and open it again. Pairings and settings are kept.

**Updates:** once a day, DyskLink reads the public list of releases on GitHub, for the Mac app and for the Android
app. A newer Mac version, and any connected phone with an older DyskLink, show together under
**Advanced > General > Updates**, with Install, Download, Skip, and Check now. While one is waiting, **Advanced** shows
an **Update** label and opens straight to it, and a new Mac version sends one notification. **Install and restart**
downloads the zip, checks that it is DyskLink signed with the same certificate as the copy you have, swaps the app,
and opens it again. Nothing is downloaded until you choose it. The check can be turned off in the same place.

**Moving from 0.1:** 0.2.0 changes the bundle ID from `id.phonelink.mac` to `id.dysklink.mac`. Pairings, keys, and
Clipboard History stay, and settings are copied over on the first launch. macOS sees a new app, so allow
Accessibility, Screen Recording, and notifications again, and turn **Open at login** off and on.

| Pairing | Clipboard History |
| --- | --- |
| ![Pairing with a code](docs/screenshots/01-pairing.png) | ![Clipboard History](docs/screenshots/03-clipboard-history.png) |
| **Notch** | **Window Previews** |
| ![Notch panel](docs/screenshots/04-notch.png) | ![Window Previews](docs/screenshots/05-window-previews.png) |

## With your phone
- **Connection:** encrypted pairing, multiple devices, automatic reconnection, and phone status such as battery,
  storage, and signal. With USB debugging on, a plugged-in phone moves to the cable within a few seconds. That needs
  `adb` (Android SDK, Homebrew `android-platform-tools`, or the Download button in a phone's settings).
- **Files:** send files both ways. Files from the phone go to Downloads/DyskLink.
- **Clipboard:** copies on the Mac go to the phone, and the phone can send its copies back.
- **Remote control:** use the phone as a touchpad, keyboard, air mouse, media remote, presentation remote, or Stream
  Deck, and run Mac commands you've listed in advance. A terminal on the Mac from the phone works once you allow it
  here, and the phone asks for its fingerprint or screen lock each time.
- **Typing from the phone:** barcodes and QR codes the phone scans, and words it hears with voice typing, are typed
  where the cursor is. Documents scanned on the phone arrive as a PDF with a text layer.
- **Phone data:** notifications, SMS, call alerts, contacts with vCard export, and read-only access to phone files.
  One-time codes from SMS and notifications show under the notch with a Copy button.
- **Phone screen:** see the phone's screen on the Mac, with its sound, and control it with your mouse and keyboard.
  The controller button maps keyboard keys to spots on the phone screen for games: joysticks (WASD, arrows, or your
  own keys), skill aim with the mouse, swipes, and keys that hold, auto-fire, or play a combo.
- **Phone camera:** a phone's camera in its own window, with lens switch, light, mirror, rotate, and keep on top.
  The phone starts it only after a tap. To use it in Zoom or Meet, add the window to OBS with Window Capture and use
  OBS Virtual Camera. The screen and camera windows have a clean view without the button bar (Command-B brings it
  back).
- **Gallery and photo sync:** browse the phone's photos and videos, newest first, in the phone's Gallery tab. Click
  one to open it, or right-click to save it to Downloads. With photo sync on, new photos from the phone are saved in
  Pictures > DyskLink > <phone name>.
- **Sound:** turn on **Let phones hear this Mac** and a phone can play this Mac's sound, for music on earphones or in
  another room. The phone can also play its own sound on the Mac (Android 10 or later). The sound is about 0.1 to
  0.5 seconds behind.
- **This screen on the phone:** with **View this screen from the phone** on in a phone's settings, that phone can view
  this screen and tap, type, and scroll on it. **Second display** on the phone adds it as an extra display of this
  Mac, which you arrange in System Settings > Displays. Both need Screen Recording, and Accessibility for control.
- **Notch on the phone:** the notch's todo list, water, Pomodoro, and quick note show on the phone and can be changed
  there. The Mac keeps the data.
- **Find each other:** ring the phone from the Mac, even on silent, or ring the Mac from the phone.
- **Calls:** whatever plays on the Mac pauses when the phone rings and plays again when the call ends. It can be
  turned off on the phone's page.
- **Quick actions:** the phone's Quick Settings tiles and widgets can send the clipboard, lock the Mac, and start or
  stop Keep Awake.
- **Lock when the phone goes away:** in a phone's settings. The Mac locks when that phone stays disconnected for the
  chosen time (30 seconds to 5 minutes). It doesn't lock when the Mac itself is offline.
- **Waking the Mac:** this Mac disconnects cleanly before it sleeps, so the phone shows **Wake Mac** right away, which sends
  Wake-on-LAN. A MacBook on Wi-Fi only wakes this way on the charger with an Apple TV or HomePod on the network, or
  over Ethernet. **Advanced > Productivity > Stay reachable while charging** keeps the Mac from sleeping while it's on
  the charger, so the phone stays connected. The display still turns off, and on battery it sleeps as usual.
- **File history:** every file sent or received with any device, under **File history** in the sidebar.

Phone data, screen, and control are off until you turn them on from the phone. The Mac keeps phone data in memory
only. It's cleared when a feature is turned off or the devices unpair. Contacts reach the disk only if you press
Export vCard, and downloaded files go to Downloads/DyskLink.

## Other computers
Turn on **Advanced > Productivity > Other computers** on two or more computers on the same network: other Macs, and
Windows or Linux PCs running [DyskLink for Windows and Linux](https://github.com/DyskLab/dysklink-desktop). Pair them
with the 6-digit code.

- **Clipboard and files:** text and pictures you copy on one can be pasted on the others. When two Macs connect, the
  newest 500 text copies in Clipboard History are merged too. Files can be sent between them, and each can ring the
  other. Everything goes straight between the computers, encrypted. A paired computer can't run commands.
- **One mouse and keyboard:** under **Mouse and keyboard**, choose which side of this Mac another computer sits on,
  and turn on **Let paired computers use their mouse and keyboard here** on that computer (off by default). Push the
  pointer past that edge to use it, and back to come home; Control-Option-Command brings it home at once. This works
  both ways with Macs and Windows PCs. A Linux PC can take the Mac's mouse and keyboard on Wayland or X11, but can
  only push its own into the Mac on X11. Control comes back when the other computer sleeps, locks, or stops
  answering for 3 seconds, and the pointer never crosses in the middle of a drag. Macs need Accessibility. Copy and
  paste works across through the shared clipboard.

## Advanced tools
Open **Advanced** at the bottom of the sidebar. Its pages are General, Productivity, Windows, Screen, and Notch.
**General** holds:

- **Appearance:** System, Dark, or Light. Dark is the default. The notch and the phone screen and camera windows
  stay dark.
- **Open at login:** starts DyskLink in the menu bar when you log in. If you move the app afterward, turn it off and
  on again.
- **Menu bar:** chooses what the DyskLink menu shows and in what order: devices, brightness and volume, Keep Awake,
  window layouts, recent copies, ring phone, lock screen, Pomodoro, weather, quick note, and Open at login.
- **Updates:** see [Download](#download).

The tools:

- **System Monitor:** CPU, memory, disk, network, battery, and the busiest apps. It only samples while the page
  is on screen.
- **Keep Awake:** keeps the Mac or its screen awake for a set time or until you stop it, optionally only while
  plugged in, until the battery falls below a limit, or until there's been no activity for a time you choose. It
  holds a macOS power assertion and changes no settings.
- **Clipboard History:** **Control + Command + V** shows what you copied, and Return pastes it. It can keep up to
  1000 or 5000 items, or everything, and **Control + Option + 1 to 9** can paste the newest items directly. History
  from Ditto (`Ditto.db` from Windows) and CopyQ (a `.cpq` export without a password, or `~/.config/copyq`) can be
  imported.
  **Control + Command + O** copies the text in part of the screen, and both shortcuts can be changed. Items stay in
  Application Support on this Mac, readable only by your account, up to 200 items and 30 images by default, which you can change, plus anything
  pinned. Content marked private or temporary is always skipped. **Ignore passwords**, on by default, also skips
  copies from password apps and one-word text that mixes letters, numbers, and symbols. A plain word used as a
  password can still be saved, and some codes can be skipped by mistake.
- **Brightness and Volume:** sliders on the page and in the menu bar for the built-in screen, external monitors,
  and the sound output, with one slider for all screens. The brightness keys can control every screen too. Monitors
  are controlled over DDC/CI, and a monitor that doesn't answer has its picture dimmed instead. **Allow darker** lets
  the bottom quarter of the slider darken the picture below the backlight's minimum.
- **Mouse:** turns off pointer acceleration, sets pointer speed, reverses the wheel, or scrolls a fixed distance
  per notch, for external mice only. Command, Shift, Option, Control, and Option + Control with the wheel can each
  scroll sideways, faster, or slower, zoom, or change volume or brightness. Settings go back when you turn this off
  or quit, and after a crash they go back when the mouse reconnects or the Mac restarts.
- **Window Previews:** point at a Dock icon to see that app's windows, then click to focus, minimize, or close one.
  **Option + Tab** switches between windows, with pictures of the windows or app icons only. It lists windows on the
  current Space and minimized windows. To catch this shortcut, the app checks which key each press is, without
  storing or sending it. The panels can use the default look or Liquid Glass.
- **Window Layout:** **Control + Option** with an arrow, D, F, G, E, T, U, I, J, K, C, or Return puts the front window
  in a half, third, two thirds, quarter, the center, or the whole screen. Add Command to move it to the other screen,
  or press Control + Option + Shift + G to put every window on the screen into a grid. Layouts of all open windows
  can be saved and restored from Advanced, the menu bar, or the Launcher.
- **Launcher:** **Option + Space** opens a search box for apps, files, open windows, recent copies, sums, units such
  as `10 km to mi`, and DyskLink actions. Files come from the Spotlight index. DyskLink doesn't change macOS
  settings, so to use Command + Space, turn off Spotlight's shortcut first.
  Start with `f ` for files only, `d ` for folders only, or `:` (or `e `) for emoji: type a name in English or
  Indonesian, Return types it into the app in front, and Command + Return copies it.
- **Notch:** point at or click the top of the built-in screen, or a thin bar on the main screen with the lid closed,
  for music controls, a Pomodoro timer, a todo list, a water reminder, prayer times, weather, Mac and phone batteries, a file shelf, a
  quick note, recent copies, and the phone's notifications. Lyrics can show beside the player. They are off by default, because they
  send the song's title and artist to [LRCLIB](https://lrclib.net), and the lines only follow the song in Spotify,
  since Music and YouTube don't share the position. Each page can be hidden, and the Pomodoro focus length, breaks, and number of sessions can be changed. Song titles come from Music
  and Spotify, and from YouTube in Firefox, Safari, Chrome, and other browsers: while the panel is open, it reads
  browser window titles with Accessibility, so a video shows when its tab is the one in front, without its length or
  channel. The buttons control whichever player is active. The shelf only remembers where files are, and files dropped
  on **Send to phone** go to the connected phone. The water reminder counts what you drink with a **Drink** button, shows today's total and a chart by hour, and can
  remind you during the hours you choose until the goal is reached. The last 7 days stay on this Mac. The todo list keeps up to 50 tasks on this Mac, adds them from a small box that opens from the notch or from
  **Advanced > Notch**, and drops tasks finished on an earlier day. Prayer times and weather appear once you choose a city under
  **Advanced > Notch**. Prayer times come from equran.id, for cities in Indonesia, and a month is saved on this Mac so
  they keep working offline. Prayer notifications are off until you turn them on and only run while the Notch is on.
  A short warning also shows in the notch when the connected phone falls to 10 to 30% (20% by default) and when it
  reaches 100% while charging. It can also send a notification, which is off by default.
  Weather comes from Open-Meteo, which receives the city you search for and its coordinates, and nothing else. On a screen with a camera, the panel's menu starts below it. On a screen with no camera, the
  closed bar is hidden unless you turn off **Hide the bar on screens without a camera**. **Fit more icons beside the
  camera** brings menu bar icons closer together after you log out and back in, without changing the screen size.

Brightness, Mouse, and Window Previews use private Apple APIs looked up at run time, so a macOS update could
disable them.

## Codes in the notch

One-time codes from the phone's SMS and notifications show under the notch with a Copy button for 30 seconds. The copied
code isn't kept in the clipboard history or sent to phones. Turn it off with Codes in the notch in the phone's settings.

## Mac care

**Mac care** in the sidebar tidies this Mac. Nothing is removed without asking, and everything goes to the Trash, so it can be put back.

- **Cleaner:** app caches, logs, developer files (Xcode DerivedData, simulator caches, Gradle and npm caches), installers and old files in Downloads, and files of 500 MB or more. Caches, logs, and developer files start ticked; your own files never do.
- **Duplicates:** files saved more than once in the folders you pick. Copies must match byte for byte, and one copy of each is always kept.
- **Uninstall:** apps in Applications with the settings, caches, and data they left in your Library. Files carrying the app's ID are ticked; ones that only share its name are left for you to check.
- **Startup:** turn your account's background agents off and on again, or remove them. Agents for all users are shown to check, since changing them needs an administrator. Login items open in System Settings.
- **Battery:** health as in System Settings, full charge against design, cycles, temperature, power, and a daily
  history. The menu bar shows where the power goes.
- **Charging control:** a charge limit with sailing, discharge while on power, heat protection, and calibration,
  through a small root helper (`dysklink-power`) that can only switch the charger input. Its launchd guard turns the
  charger back on if DyskLink isn't running or the battery is below 10%. **Remove helper** undoes the install.

## Permissions
- **Accessibility:** for the touchpad, keyboard, and remotes from the phone, typing scanned or dictated text,
  control of this screen from the phone, sharing the mouse and keyboard with other computers, pasting from Clipboard
  History, Mouse wheel options (which only look at scroll events), and Window Previews.
- **Screen Recording:** for this screen and the second display on the phone, reading text from the screen, and
  window pictures in Window Previews.
- **Notifications:** requested the first time the notification, SMS, or call feature turns on.

Builds signed with the certificate below keep the Accessibility grant across rebuilds. An ad-hoc build loses the
grant with every build, even though the switch still looks on in Settings. To redo it, press **Allow** in the app,
then turn DyskLink on in Settings.

## Build and run
You need macOS 15 or later. The Command Line Tools are enough.

```bash
git clone https://github.com/DyskLab/dysklink-mac.git
cd dysklink-mac
```

For a quick debug build and a check of the Advanced tools:
```bash
swift build
.build/debug/PhoneLinkMac --tools-selftest
```

To build the app, create the signing certificate once per Mac:
```bash
./scripts/create-signing-cert.sh
```

The first build that uses it shows a Keychain dialog. Enter your own login password and choose **Always Allow**.
```bash
./scripts/bundle.sh
open dist/DyskLink.app
```

`bundle.sh` builds a release `dist/DyskLink.app` with the charging helper inside. To remove the certificate:
```bash
security delete-identity -c "DyskLink Local Signing"
```

When the window closes, the app keeps running from the cable icon in the menu bar. That menu has
**Open at login** and **Quit**.

Then [install the Android app](https://github.com/DyskLab/dysklink-android#build-and-install) and open it on the same
network. The phone asks to pair, the Mac shows a 6-digit code, and you type it on the phone. The code is new each time
and only works for that pairing. After that, connecting is automatic.

## Tests
The test scripts run debug Mac apps with a separate port, folders, and clipboard, without injecting input. Run one
at a time.

```bash
./scripts/integration-test.sh   # the Android core against the Mac app over real TLS
./scripts/pc-sync-test.sh       # the Windows/Linux computer side against the Mac app
./scripts/mac-sync-test.sh      # two Mac apps pairing and sharing the clipboard
```

`integration-test.sh` and `pc-sync-test.sh` need JDK 17 and
[dysklink-android](https://github.com/DyskLab/dysklink-android) cloned next to this repository.
`integration-test.sh` finds it as `dysklink-android` or `android`, or in `DYSKLINK_ANDROID_DIR`, and also needs the
Android SDK. `pc-sync-test.sh` expects it at `../android`.

Phone data in these tests is fake. The video decoder is tested with H.264 made by VideoToolbox, not with phone encoder
output.

## Development
Debug builds support:
- `PhoneLinkMac --snapshot <folder>`: renders PNGs of the main screens, in the light theme with
  `DYSKLINK_SNAPSHOT_APPEARANCE=light`.
- `PhoneLinkMac --render-icon <file.png>`: renders the 1024x1024 app icon source.
- `PhoneLinkMac --video-selftest`: tests the video decoder.
- `PhoneLinkMac --tools-selftest`: tests the Advanced tools.
- `PhoneLinkMac --update-check <version>`: asks GitHub for a newer release than that version and prints it.
- `PHONELINK_DATA_DIR=<folder>`: uses a separate data folder.
- `PHONELINK_TEST_AUTO_ACCEPT=1`: accepts pairing automatically, for testing only.
- `PHONELINK_PORT`, `PHONELINK_DOWNLOAD_DIR`, `PHONELINK_TEST_DRY_RUN=1`, `PHONELINK_TEST_SEND_FILE`, and
  `PHONELINK_TEST_PROBE_PHONE=1`: used by the integration test script.

None of these exist in release builds.

Both apps speak the protocol in [docs/PROTOCOL.md](docs/PROTOCOL.md). A change to it needs a matching change in
[dysklink-android](https://github.com/DyskLab/dysklink-android).

## Current security limits
Private keys are stored as files with restricted permissions in the app data folder, not yet in the Keychain.

## Internal names
The app's display name and bundle ID (`id.dysklink.mac`, since 0.2.0) use DyskLink. The old name PhoneLink remains in
the `_phonelink._tcp` network service, the Swift target, and the data folder, because changing them would erase
existing pairings or stop older phones from finding the Mac.

## Support
DyskLink is free and open source under the [MIT License](LICENSE). If it helps you, you can
[buy me a coffee](https://buymeacoffee.com/fannydevz).

## Part of DyskLab
DyskLink is part of [DyskLab](https://dysklab.fanny.dev), alongside
[DyskFlow](https://github.com/DyskLab/dyskflow), [DyskFiles](https://github.com/DyskLab/dyskfiles), and
[DyskFocus](https://github.com/DyskLab/dyskfocus).
