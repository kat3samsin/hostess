# Homebrew cask

The live cask is [Casks/hostess.rb](../../Casks/hostess.rb). This repository also serves as the project's Homebrew tap:

```bash
brew tap kat3samsin/hostess https://github.com/kat3samsin/hostess.git
brew install --cask kat3samsin/hostess/hostess
```

It installs the published v0.2.0 Apple Silicon ZIP and verifies its SHA-256. The app is ad hoc signed and not notarized. Users approve its first launch through macOS where permitted. Profile changes require administrator approval; this archive cannot enable passwordless switching.

This is a project tap. Official Homebrew casks must pass [Homebrew's Gatekeeper checks](https://docs.brew.sh/FAQ#why-was-a-cask-disabled-or-removed-after-a-macos-security-check). The cask leaves macOS security checks enabled.

## Update the cask

Build the archive that Homebrew installs:

```bash
Scripts/package_app.sh
```

The script creates an ad hoc signed ZIP and its SHA-256 file in `.build/releases`. On Apple Silicon, the archive is `Hostess-0.2.0-arm64-unnotarized.zip`. GitHub release assets host the archive used by the cask. Keep those assets available and direct users to the Homebrew installation instructions.

1. Build and publish a versioned archive with its SHA-256 file.
2. Update the version, URL, SHA-256, architecture, and macOS requirement in `Casks/hostess.rb`.
3. Check the cask with `brew style Casks/hostess.rb`.
4. Test installation, launch, profile switching, and removal on a disposable Mac before publishing the update.

Keep the cask's caveats consistent with the artifact. A successful checksum check does not verify first launch or privileged operations.

## Removal

Uninstalling first runs the installed app's `--unregister-helper` command as the current user. That command unregisters the managed helper. Cleanup then disables and removes the legacy helper and deletes both helpers' fixed configuration paths. The privileged cleanup runs only system executables. It stops on unexpected failures.

An ordinary uninstall keeps profiles and the current `/etc/hosts` contents. `brew uninstall --cask --zap hostess` also removes the saved Hostess profiles and preferences. Back up profiles before using `--zap`.

The uninstall declarations follow Homebrew's [Cask Cookbook](https://docs.brew.sh/Cask-Cookbook#stanza-uninstall). Test removal on a disposable Mac before changing the helper cleanup.
