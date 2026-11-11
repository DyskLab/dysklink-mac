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

DyskLink also adds a set of optional tools to the Mac, each off until you turn it on.

**This is the Mac app. The phone app is [DyskLink for Android](https://github.com/DyskLab/dysklink-android).**
You need both to use the phone features. The Advanced tools work on the Mac alone.

> DyskLink is in early development, so expect rough edges.

## Download
You need macOS 15 or later on Apple Silicon.

1. Download `DyskLink-mac-arm64.zip` from the [latest release](https://github.com/DyskLab/dysklink-mac/releases/latest),
   unzip it, and move **DyskLink** to Applications.
2. The app isn't notarized, so macOS blocks the first launch. Open **System Settings > Privacy & Security** and choose
   **Open Anyway**.
3. [Install the Android app](https://github.com/DyskLab/dysklink-android#download) and open it on the same network.

This download uses a self-signed certificate, not one from Apple. To run on Intel,
[build it from source](#build-and-run).

**Updates:** once a day, DyskLink reads the public list of releases on GitHub, for the Mac app and for the Android
app. When a newer Mac version is out, it sends one notification and shows **Download** in the sidebar and the menu
bar. **Advanced > Check for updates** also offers **Install and restart**, which downloads the zip, checks that it is
DyskLink signed with the same certificate as the copy you have, swaps the app, and opens it again. Nothing is
downloaded until you choose it. A connected phone with an older DyskLink shows a note on its page. You can turn the
check off or run it now under **Advanced > Check for updates**.

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
  storage, and signal.
- **Files:** send files both ways. Files from the phone go to Downloads/DyskLink.
- **Clipboard:** copies on the Mac go to the phone, and the phone can send its copies back.
- **Remote control:** use the phone as a touchpad, keyboard, media remote, or presentation remote, and run Mac
  commands you've listed in advance.
- **Phone data:** notifications, SMS, call alerts, contacts with vCard export, and read-only access to phone files.
- **Screen:** see the phone's screen on the Mac and control it with your mouse and keyboard.
- **Gallery:** browse the phone's photos and videos, newest first, in the phone's Gallery tab. Click one to open it,
  or right-click to save it to Downloads.
- **Sound:** turn on **Let phones hear this Mac** and a phone can play this Mac's sound, for music on earphones or in
  another room. The phone can also play its own sound on the Mac (Android 10 or later), and the phone's screen
  window carries its sound, with a mute button. The sound is about 0.1 to 0.5 seconds behind.
- **Notch on the phone:** the notch's todo list, water, and Pomodoro show on the phone and can be changed there.
  The Mac keeps the data.
- **Find each other:** ring the phone from the Mac, even on silent, or ring the Mac from the phone.
- **Calls:** whatever plays on the Mac pauses when the phone rings and plays again when the call ends. It can be
  turned off on the phone's page.
- **Quick actions:** the phone's Quick Settings tiles and widget can send the clipboard, lock the Mac, and start or
  stop Keep Awake.
- **File history:** every file sent or received with any device, under **File history** in the sidebar.
- **Other Macs:** turn on **Advanced > Other Macs** on two or more Macs on the same network, pair them with the
  6-digit code, and text you copy on one can be pasted on the others. When they connect, the newest 500 text copies
  in Clipboard History are merged too. Files can be sent between them, and each can ring the other. A paired Mac
  can't control the mouse, keyboard, or commands. Everything goes straight between the Macs, encrypted.

Phone data, screen, and control are off until you turn them on from the phone. The Mac keeps phone data in memory
only. It's cleared when a feature is turned off or the devices unpair. Contacts reach the disk only if you press
Export vCard, and downloaded files go to Downloads/DyskLink.

## Advanced tools
Open **Advanced** at the bottom of the sidebar. **Open at login** at the top of the page starts DyskLink in the
menu bar when you log in. If you move the app afterward, turn it off and on again.

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
  for music controls, a Pomodoro timer, a todo list, a water reminder, prayer times, weather, Mac and phone batteries, a file shelf, recent
  copies, and the phone's notifications. Lyrics can show beside the player. They are off by default, because they
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

## Permissions
- **Accessibility:** for the touchpad, keyboard, and remotes from the phone, pasting from Clipboard History, Mouse
  wheel options (which only look at scroll events), and Window Previews.
- **Screen Recording:** for reading text from the screen and for window pictures in Window Previews.
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

Create the signing certificate once per Mac:
```bash
./scripts/create-signing-cert.sh
```

The first build that uses it shows a Keychain dialog. Enter your own login password and choose **Always Allow**.
```bash
./scripts/bundle.sh
open dist/DyskLink.app
```

To remove the certificate:
```bash
security delete-identity -c "DyskLink Local Signing"
```

When the window closes, the app keeps running from the cable icon in the menu bar. That menu has
**Open at login** and **Quit**.

Then [install the Android app](https://github.com/DyskLab/dysklink-android#build-and-install) and open it on the same
network. The phone asks to pair, the Mac shows a 6-digit code, and you type it on the phone. The code is new each time
and only works for that pairing. After that, connecting is automatic.

## Tests
The integration test runs the Android core against the debug Mac app over real TLS, with a separate port, folders,
and clipboard, and without injecting input. It needs JDK 17, the Android SDK, and
[dysklink-android](https://github.com/DyskLab/dysklink-android) cloned next to this repository, or its location in
`DYSKLINK_ANDROID_DIR`.

```bash
./scripts/integration-test.sh
```

Phone data in this test is fake. The video decoder is tested with H.264 made by VideoToolbox, not with phone encoder
output.

## Development
Debug builds support:
- `PhoneLinkMac --snapshot <folder>`: renders PNGs of the main screens.
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

## Lock, note, battery

- **Lock when the phone goes away:** in a phone's settings on the Mac. The Mac locks when that phone stays disconnected
  for the chosen time (30 seconds to 5 minutes). It doesn't lock when the Mac itself is offline.
- **Quick note:** the Note page in the notch and Quick note on the phone's Notch screen hold the same text.
- **Battery:** Mac care › Battery shows health as in System Settings, full charge against design, cycles, temperature,
  power, and a daily history.
- **Menu bar:** Advanced › Menu bar chooses what the DyskLink menu shows and in what order: devices, brightness and volume,
  Keep Awake, window layouts, recent copies, ring phone, lock screen, Pomodoro, weather, quick note, and Open at login.
- **Screen on the phone:** with "View this screen from the phone" on (in a phone's settings), paired phones can view this
  screen and tap, type, and scroll on it. It needs Screen Recording, and Accessibility for control.
- **Photo sync:** photos the phone sends with photo sync on are saved in Pictures › DyskLink › <phone name>.
- **Phone camera:** a phone's camera in its own window, with lens switch, light, mirror, rotate, keep on top, and a clean
  view for OBS Window Capture. Use OBS Virtual Camera to bring it into Zoom or Meet.
- **OBS:** the phone screen and camera windows have a clean view without the button bar (⌘B brings it back) and a keep on
  top button. Add them to OBS with Window Capture.
- **USB:** with USB debugging on, a plugged-in phone connects through the cable instead of Wi-Fi. Needs `adb` (Android SDK,
  Homebrew `android-platform-tools`, or the Download button in a phone's settings).
- **Game keys:** in the phone screen window, the controller button maps keyboard keys to spots on the phone screen, plus a
  WASD joystick. Several keys can be held at once, and the mouse taps as well.
- **Phone as a second display:** Second display on the phone adds it as an extra display of this Mac. Drag windows onto it
  and arrange it in System Settings › Displays. Needs "View this screen from the phone" and Screen Recording.
- **Charging control:** Mac Care › Battery. Charge limit with sailing, discharge on power, heat protection, and calibration,
  through a small root helper (`dysklink-power`) that can only switch the charger input. Its launchd guard turns the
  charger back on if DyskLink isn't running or the battery is below 10%. Remove helper undoes the install.
