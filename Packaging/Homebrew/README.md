# Homebrew Cask

This template is for a future signed, notarized release. The current unnotarized ZIP is available through the [direct download instructions](../../README.md#download).

Build the release with a Developer ID Application certificate and an existing `notarytool` keychain profile:

```bash
export HOSTESS_SIGNING_IDENTITY='Developer ID Application: YOUR NAME (TEAMID)'
export HOSTESS_NOTARY_PROFILE='YOUR_NOTARYTOOL_KEYCHAIN_PROFILE'
Scripts/release_app.sh
```

The script signs the helper first, then the app. It checks both signatures, their matching Team IDs, and hardened runtime. It submits the app to Apple, requires an accepted result, staples and validates the ticket, and checks Gatekeeper before creating `.build/releases/Hostess-0.2.0.zip`. The script prints the archive's SHA-256 hash. It stops if that release filename already exists.

`Scripts/build_app.sh` defaults to a local ad hoc signature. Use `Scripts/release_app.sh` for this signed cask workflow. The archive contains the architecture built on your Mac; declare the supported architecture in the cask if you publish a single-architecture build.

Publish the cask:

1. Upload `Hostess-0.2.0.zip` to a GitHub release or another stable URL.
2. Copy `Packaging/Homebrew/Casks/hostess.rb.template` to `hostess.rb`.
3. Set the release version and replace the `url`, `homepage`, and `sha256` placeholders.
4. Put `hostess.rb` in a Homebrew tap under `Casks/hostess.rb`.

Local cask test:

```bash
brew install --cask ./Casks/hostess.rb
```

Uninstalling first runs the installed app's `--unregister-helper` command as the current user. That command unregisters the managed helper. Cleanup then disables and removes the legacy helper and deletes both helpers' fixed configuration paths. The privileged cleanup runs only system executables. It stops on unexpected failures.

An ordinary uninstall keeps profiles and the current `/etc/hosts` contents. `brew uninstall --cask --zap hostess` also removes the saved Hostess profiles and preferences. Back up profiles before using `--zap`.

The uninstall template follows Homebrew's [Cask Cookbook](https://docs.brew.sh/Cask-Cookbook#stanza-uninstall). Test installation, helper registration, and removal on a disposable Mac before publishing the cask.
