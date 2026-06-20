# Mockingbird

Mockingbird is a self-contained macOS menu bar app that reads selected text aloud with local TTS.

## What It Owns

- Global hotkeys, no Apple Shortcuts app required.
- Cold-start synthesis: no Python speech process stays resident while idle.
- Self-contained speech runtime in the app bundle for shipped builds.
- Menu bar controls for setup status, generation state, playback progress, pause/resume, stop, voice settings, audio cache, and editable hotkeys.

Default hotkeys:

- Read selection / stop current reading: `Control + Option + S`
- Pause/resume: `Control + Option + P`

You can edit them from the Mockingbird menu.

## Build And Launch

```bash
scripts/package_app.sh
scripts/launch.sh
```

The packaged app lives at:

```bash
Mockingbird.app
```

## Ship To Another Mac

Build a DMG, then share `dist/Mockingbird.dmg`:

```bash
scripts/export_dmg.sh
```

The recipient can open the DMG, drag `Mockingbird.app` to Applications, and launch it. Shipped builds use the bundled speech helper, so the recipient does not need Python, Homebrew, or developer tools installed.

Generated audio and local request state live in:

```bash
~/Library/Application Support/Mockingbird
```

Development builds can still use the older first-run setup flow when packaged with `MOCKINGBIRD_SKIP_SPEECH_HELPER=1`.

You can also create a zip archive with:

```bash
scripts/export_app.sh
```

Shipped packages build and embed a frozen speech helper at:

```bash
Mockingbird.app/Contents/Resources/speech-helper/MockingbirdSynth/MockingbirdSynth
```

The helper is built by `scripts/build_speech_helper.sh` using a Python 3.10+ environment that already contains Kokoro, Torch, NumPy, and SoundFile. The script prefers Mockingbird's existing private runtime at:

```bash
~/Library/Application Support/Mockingbird/.venv/bin/python
```

Install PyInstaller into that environment before exporting a DMG:

```bash
"$HOME/Library/Application Support/Mockingbird/.venv/bin/python" -m pip install pyinstaller
```

Local builds are ad-hoc signed by default. For a DMG intended for other Macs without Gatekeeper workarounds, sign with a Developer ID Application certificate:

```bash
MOCKINGBIRD_CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" scripts/export_dmg.sh
```

To reuse an already-built frozen helper while iterating on packaging:

```bash
MOCKINGBIRD_REUSE_SPEECH_HELPER=1 scripts/package_app.sh
```

For a local development package that keeps the old first-run Python setup flow, set:

```bash
MOCKINGBIRD_SKIP_SPEECH_HELPER=1 scripts/package_app.sh
```

## Local Runtime

Mockingbird keeps generated audio and request files in its Application Support folder, not in this repository. Local helper scripts such as `scripts/read-selected.sh`, `scripts/pause.sh`, and `scripts/stop.sh` send commands to that runtime folder.

## Privacy

Mockingbird does not listen to your microphone. It only reads selected text when you press the read hotkey. Shipped builds launch a local bundled speech helper for each read, then that process exits.
