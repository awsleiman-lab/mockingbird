# Mockingbird

Mockingbird is a self-contained macOS menu bar app that reads selected text aloud with local TTS.

## What It Owns

- Global hotkeys, no Apple Shortcuts app required.
- Cold-start synthesis: no Python speech process stays resident while idle.
- First-run setup: if `.venv` is missing, Mockingbird runs `scripts/setup.sh` to install the speech engine and download model assets.
- Menu bar controls for generation state, playback progress, pause/resume, stop, and editable hotkeys.

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

Copy this whole `Mockingbird` folder. On the other Mac:

```bash
scripts/package_app.sh
scripts/launch.sh
```

If `.venv` is not present, the app will install the speech engine on first launch. That first launch needs internet access for Python packages and model assets. After setup, text-to-speech is local.

## Privacy

Mockingbird does not listen to your microphone. It only reads selected text when you press the read hotkey. It launches a local Python speech process for each read, then that process exits.
