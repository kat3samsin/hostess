# Homebrew cask

The live cask is [Casks/hostess.rb](../../Casks/hostess.rb). This repository also serves as the project's Homebrew tap:

```bash
brew tap kat3samsin/hostess https://github.com/kat3samsin/hostess.git
brew install --cask kat3samsin/hostess/hostess
```

It installs the published v0.2.0 Apple Silicon ZIP and verifies its SHA-256. The app is ad hoc signed and not notarized. Users approve its first launch through macOS where permitted. Profile changes require administrator approval; this archive cannot enable passwordless switching.

This is a project tap. Official Homebrew casks must pass [Homebrew's Gatekeeper checks](https://docs.brew.sh/FAQ#why-was-a-cask-disabled-or-removed-after-a-macos-security-check). The cask leaves macOS security checks enabled.

## Update the cask

1. Build and publish a versioned archive with its SHA-256 file.
2. Update the version, URL, SHA-256, architecture, and macOS requirement in `Casks/hostess.rb`.
3. Check the cask with `brew style Casks/hostess.rb`.
4. Test installation, launch, profile switching, and removal on a disposable Mac before publishing the update.

Keep the cask's caveats consistent with the artifact. A successful checksum check does not verify first launch or privileged operations.

## Signed release

Build the release with a Developer ID Application certificate and an existing `notarytool` keychain profile:

```bash
export HOSTESS_SIGNING_IDENTITY='Developer ID Application: YOUR NAME (TEAMID)'
export HOSTESS_NOTARY_PROFILE='YOUR_NOTARYTOOL_KEYCHAIN_PROFILE'
Scripts/release_app.sh
```

The script signs the helper first, then the app. It checks both signatures, their matching Team IDs, and hardened runtime. It submits the app to Apple, requires an accepted result, staples and validates the ticket, and checks Gatekeeper before creating `.build/releases/Hostess-0.2.0.zip`. The script prints the archive's SHA-256 hash. It stops if that release filename already exists.

`Scripts/build_app.sh` defaults to a local ad hoc signature. Use `Scripts/release_app.sh` for this signed cask workflow. The archive contains the architecture built on your Mac; declare the supported architecture in the cask if you publish a single-architecture build.

Publish the signed ZIP under a new release version, then update the live cask. The [signed-release template](Casks/hostess.rb.template) provides the archive naming and cleanup declarations; its placeholders need real release values. Keep the architecture and macOS declarations from the live cask and update the caveats to describe the signed release.

## Removal

Uninstalling first runs the installed app's `--unregister-helper` command as the current user. That command unregisters the managed helper. Cleanup then disables and removes the legacy helper and deletes both helpers' fixed configuration paths. The privileged cleanup runs only system executables. It stops on unexpected failures.

An ordinary uninstall keeps profiles and the current `/etc/hosts` contents. `brew uninstall --cask --zap hostess` also removes the saved Hostess profiles and preferences. Back up profiles before using `--zap`.

The uninstall declarations follow Homebrew's [Cask Cookbook](https://docs.brew.sh/Cask-Cookbook#stanza-uninstall). Test helper registration and removal on a disposable Mac when changing to a signed release.
