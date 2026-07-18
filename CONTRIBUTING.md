# Contributing to Mockingbird

Thanks for contributing. Please open an issue to discuss substantial changes before beginning implementation, and keep pull requests focused.

## Development setup

Mockingbird is a Swift Package Manager macOS 14+ app. Build it with a full Xcode installation:

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
git diff --check
```

This package currently has no test target, so contributors should not claim that `swift test` is part of its verification. For an app bundle smoke test, use:

```bash
scripts/package_app.sh
scripts/launch.sh
```

`scripts/export_app.sh` creates a ZIP and `scripts/export_dmg.sh` creates a DMG; these are packaging workflows, not CI checks. Do not run `scripts/release.sh` for a contribution.

## Pull requests

- Keep changes narrowly scoped and explain the user impact.
- Add tests when a test target is introduced or when relevant coverage exists.
- Do not add dependencies or change packaging/release behavior without prior discussion.
- State the build or packaging checks you ran.

## Reporting security issues

Please follow [SECURITY.md](SECURITY.md) for vulnerabilities. Do not report security issues in public issues or pull requests.
