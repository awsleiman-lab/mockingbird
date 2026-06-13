# Mockingbird

Mockingbird is a self-contained macOS menu bar app that reads selected text aloud with local TTS.

## What It Owns

- Global hotkeys, no Apple Shortcuts app required.
- Cold-start synthesis: no Python speech process stays resident while idle.
- First-run setup: Mockingbird installs its private speech runtime into `~/Library/Application Support/Mockingbird`.
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

Build the app, then share `Mockingbird.app`:

```bash
scripts/package_app.sh
```

The recipient can drag `Mockingbird.app` to `/Applications` and launch it. On first launch, Mockingbird checks its private runtime in:

```bash
~/Library/Application Support/Mockingbird
```

If the speech engine is missing or broken, the app shows a setup panel and installs Python, Kokoro, and model assets there. First setup needs internet access. After setup, text-to-speech is local.

## Local Runtime

Mockingbird keeps generated audio and request files in its Application Support folder, not in this repository. Local helper scripts such as `scripts/read-selected.sh`, `scripts/pause.sh`, and `scripts/stop.sh` send commands to that runtime folder.

## Privacy

Mockingbird does not listen to your microphone. It only reads selected text when you press the read hotkey. It launches a local Python speech process for each read, then that process exits.
