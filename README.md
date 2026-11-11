<img src="assets/icon.svg" width="64" height="64" alt="">

# OpenHoy

A menu bar messenger for macOS that runs on **iMessage**. It needs no account, no server and no separate app, and everything goes out through your own Messages app.

<img src="assets/screenshot-panel.png" width="320" alt="OpenHoy panel"> <img src="assets/screenshot-composer.png" width="320" alt="Composer with attachments">

## What it does

- **Your people in the menu bar.** Pin as many people as you like. They sit as an overlapping stack of glass avatars that fans out when you hover, and several Messages threads for the same person (iMessage, SMS and older formats) are merged into one. Each avatar shows a dot for unread messages, a ring when that chat is open, and a pencil when you have a draft. Hover to see the name.
- **Click an avatar** to drop down a glass chat card. It has a compact header (photo, name, an iMessage/SMS chip, *Open in Messages* and expand buttons). Your messages are blue (green for SMS), theirs are frosted, and time separators are small chips. Pick another look in **Settings › Appearance**: Messages, System Accent, Graphite, Ocean or Sunset. At the bottom is a single input bar: **+**, *Message Tanya…*, and a round send button. It follows your light or dark mode.
  - **⏎** or the **↑** button sends, **⇧⏎** adds a new line, and **Esc** discards the draft (or closes the panel).
  - 🎙 **Voice notes** (mic button, or **+** › Voice Note) show a live waveform and a live on-device transcript. Press **■** or ⏎ to stop, play it back, then send. The audio goes out as an `.m4a`, and the transcript is sent as a text (you can turn this off).
  - 📎 **Files and photos**, from **+** › Attach Files, pasted with ⌘V, or **dragged onto someone's avatar** in the menu bar (or onto the panel).
  - 🫳 **Just throw stuff at them.** Start dragging files anywhere and a glass drop zone drops down under your avatars. Slide across it to pick a person (their face lights up and it says *Drop to Rodrigo*), then let go to drop the files into their chat. Turn it off in **Settings › Options**.
  - 🎥 **Video notes** from your camera, with a round live preview.
  - ⏺ **Screen recordings.** *Record Screen with Microphone ▾ Camera ▾*. Click a window, drag to select an area, or press Esc to cancel. A round face bubble follows you while recording, and the menu bar shows a red stop button.
- **Messages from your history:** text, photos, videos, voice notes, files and tapbacks (♥ 👍 👎 HA ‼ ? and emoji). Edited messages show *Edited*, unsent ones a short notice, and your latest message shows *Sent*, *Delivered*, *Read* or *Not Delivered* exactly as Messages recorded it. New messages and changes appear almost immediately (OpenHoy watches the database instead of polling it).

## Install

Download the latest `OpenHoy-<version>-macOS.zip` from [Releases](https://github.com/farhansrambiyan/openhoy/releases/latest), unzip it, and move **OpenHoy.app** to Applications. Then remove the download quarantine, because the app is ad-hoc signed and not notarized:

```sh
xattr -dr com.apple.quarantine /Applications/OpenHoy.app
```

Open it, then grant **Full Disk Access** and **Messages** access when the setup window asks. The full steps, including what to do after updating, are in [docs/INSTALL.md](docs/INSTALL.md).

## How it works with iMessage

| | |
|---|---|
| Reading | `~/Library/Messages/chat.db` (SQLite, read-only) via Full Disk Access. Text stored only in the `attributedBody` field is decoded too. |
| Sending | Messages.app through AppleScript (`osascript`). Files are first copied to `~/Pictures/OpenHoy Outbox/`, because Messages rejects scripted attachments from other folders. Copies are removed after 24 hours. |
| Names and photos | Contacts framework, matched on phone number or email. |
| Transcription | `SFSpeechRecognizer`, on-device when available. |
| Screen recording | ScreenCaptureKit's `SCRecordingOutput`, saved as H.264 `.mp4`. |

Limitations of going through Messages.app:
- **Reactions and inline replies are shown but can't be sent.** Messages has no scripting command for them.
- Voice notes arrive as audio files, not as the native iMessage voice-note bubble.
- Read receipts aren't changed. Opening a chat in OpenHoy only clears OpenHoy's own unread dot.

## Build from source

Requires macOS 15 or later and the Xcode Command Line Tools (full Xcode isn't needed).

```sh
scripts/build-app.sh             # → build/OpenHoy.app
scripts/build-app.sh --install   # → ~/Applications/OpenHoy.app and launch it
```

On first launch the settings window walks you through the permissions:

1. **Full Disk Access** (required, to read your conversations). Add OpenHoy in System Settings › Privacy & Security › Full Disk Access. OpenHoy picks it up automatically, so you don't need to relaunch.
2. **Automation → Messages** (required, to send).
3. Contacts, Microphone, Speech Recognition, Camera and Screen Recording, each only when you use that feature.

The four most recent conversations are pinned automatically. Change them in Settings or by right-clicking the avatars.

> macOS ties privacy permissions to the code signature. `scripts/build-app.sh` signs with the first *Developer ID Application* or *Apple Development* certificate in your keychain, so permissions survive rebuilds. Without one it falls back to an ad-hoc signature, and **after rebuilding you may need to re-grant Full Disk Access**. Choose a certificate with `SIGN_IDENTITY="…"`, or force ad-hoc with `SIGN_IDENTITY=-`.

### Troubleshooting: "can't give access to Messages"

macOS has no **+** button under Automation, so you can't add OpenHoy there yourself. An app only appears in that list after macOS has shown the prompt *"OpenHoy wants to control Messages"* and you've answered it.

1. Open **OpenHoy Settings** (click the menu bar icon, or right-click an avatar › Settings…) and click **Allow** next to *Messages*. OpenHoy starts Messages in the background (the prompt only appears while Messages is running), and macOS asks. Click **OK**.
2. If you clicked *Don't Allow* earlier, click **Ask Again**, or run this in Terminal and then click **Allow**:
   ```sh
   tccutil reset AppleEvents app.openhoy.OpenHoy
   ```
3. Afterwards you can turn it on or off in **System Settings › Privacy & Security › Automation › OpenHoy › Messages**.

Full Disk Access works differently: in **System Settings › Privacy & Security › Full Disk Access**, click **+** and choose OpenHoy.app. If it's already listed but not working, select it, remove it with **–**, and add it again. This is needed after every unsigned rebuild.

### Trying it without your real messages

```sh
python3 scripts/make-demo-db.py /tmp/openhoy-demo   # fake chat.db (attachments go in /tmp/openhoy-demo/att)
OPENHOY_CHAT_DB=/tmp/openhoy-demo/chat.db OPENHOY_DRY_RUN=1 OPENHOY_OPEN_FIRST=1 \
  build/OpenHoy.app/Contents/MacOS/OpenHoy
```

`OPENHOY_DRY_RUN=1` logs sends instead of talking to Messages.

## Layout

```
Sources/OpenHoy/
  App/        entry point, AppState (polling, pins, sending), per-chat ComposerModel
  iMessage/   chat.db reader, attributedBody decoder, AppleScript sender, Contacts lookup
  MenuBar/    avatar strip status item (click / hover / drag & drop), tooltip
  Panel/      floating panel, bubbles, composer, glass styling
  Media/      voice (AVAudioEngine + Speech), camera, ScreenCaptureKit recorder + selection overlay
  Settings/   permissions + pinned people window
```

Releases are published with `scripts/release.sh <version> <notes.md>`, which always appends [docs/INSTALL.md](docs/INSTALL.md) to the release notes.
