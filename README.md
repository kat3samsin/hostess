# Hostess

Hostess is a standalone macOS menu bar app for switching hosts-file profiles.

## Install with Homebrew

Install from this project's Homebrew tap:

```bash
brew tap kat3samsin/hostess https://github.com/kat3samsin/hostess.git
brew install --cask kat3samsin/hostess/hostess
```

The tap installs the current Apple Silicon release for macOS 13 or later. It is ad hoc signed and not notarized. Open Hostess from Applications, then approve it in **System Settings → Privacy & Security → Open Anyway** if macOS blocks its first launch.

This release requires administrator approval for profile changes. Installing through Homebrew does not enable passwordless switching. If replacing a signed build, choose **Disable Passwordless Switching** in that app first.

To update, run `brew upgrade --cask kat3samsin/hostess/hostess`. An ordinary `brew uninstall --cask hostess` preserves profiles and the current hosts file.

## Download

The current ZIP requires macOS 13 or later and an Apple Silicon Mac. It uses an ad hoc signature and is **not notarized**. Profile changes require administrator approval. Passwordless switching is unavailable in this download.

If replacing a signed build, choose **Disable Passwordless Switching** in that app before installing this download.

1. Download `Hostess-0.2.0-arm64-unnotarized.zip` from [GitHub Releases](https://github.com/kat3samsin/hostess/releases/tag/v0.2.0).
2. Extract the ZIP and move `Hostess.app` into `/Applications`.
3. Open Hostess. If macOS blocks it because the developer cannot be verified, dismiss the alert.
4. Open **System Settings → Privacy & Security**, scroll to Hostess, and choose **Open Anyway**.
5. Confirm **Open** when prompted. Hostess appears in the menu bar.

See [Apple's instructions for opening an unnotarized app](https://support.apple.com/en-us/102445). A managed Mac may prevent this approval.

To check the download, save its `.zip.sha256` file in the same folder. From that folder, run:

```bash
shasum -a 256 -c Hostess-0.2.0-arm64-unnotarized.zip.sha256
```

The result should end in `OK`.

## Screenshots

Edit and organize hosts profiles. These screenshots use example profiles and hostnames.

![Hostess profile editor with Default, Staging, and Local example profiles and local development hosts entries.](docs/screenshots/profile-editor.jpg)

Give each profile a name and an optional menu-bar emoji.

![Hostess New Profile dialog with an emoji and Work.hst entered as the profile name.](docs/screenshots/new-profile.jpg)

## Build from source

Source builds target macOS 13 or later and require Swift 6 (Xcode 16 or later). Use a Mac supported by your toolchain. The build targets your Mac's architecture.

```bash
swift test
Scripts/build_app.sh
open .build/app/Hostess.app
```

## Install from source

Install for the current user:

```bash
Scripts/install_app.sh
```

Install into `/Applications`:

```bash
Scripts/install_app.sh --system
```

The app bundle id is `app.hostess.Hostess`.

Ad hoc builds use administrator approval when applying a different profile. Passwordless switching requires a Developer ID signed build or a personal build signed with an Apple Development certificate. Both require one-time setup and approval in System Settings.

To install a personal build with your existing Apple Development signing identity:

```bash
HOSTESS_SIGNING_IDENTITY='Apple Development: YOUR NAME (CERTIFICATEID)' Scripts/install_app.sh --system
```

Use `security find-identity -v -p codesigning` to find the exact identity. In Hostess, choose **Enable Passwordless Switching**, authorize setup, then enable Hostess in **System Settings → General → Login Items & Extensions** if prompted. Subsequent profile switches use the helper without another password prompt. Keep using the same signing identity when rebuilding.

Passwordless switching has been verified on the maintainer's Mac with a personal Apple Development signed build. Installation and helper behavior on another Mac remain unverified.

If you used Hostess 0.1, choose **Remove Old Helper** when the updated app starts. This requires administrator approval and preserves profiles and `/etc/hosts`. You can also remove the old helper from Terminal:

```bash
sudo Scripts/uninstall_helper.sh
```

## Package a download

Create an unnotarized ZIP without an Apple Developer Program membership:

```bash
Scripts/package_app.sh
```

The script builds with an ad hoc signature and creates the ZIP and its SHA-256 checksum in `.build/releases`. On Apple Silicon, the archive is `Hostess-0.2.0-arm64-unnotarized.zip`. Publish both files together and retain the installation instructions above.

The published [Homebrew cask](Casks/hostess.rb) pins the current release URL and SHA-256. For a release that passes Gatekeeper's normal checks, use Developer ID signing and notarization through `Scripts/release_app.sh`. See [Packaging/Homebrew](Packaging/Homebrew/README.md) for release and cask maintenance instructions.

## Behavior

- Runs as a menu bar app with no Dock icon.
- Shows the active profile's leading emoji, or its name without that emoji when **Show Profile Emoji in Menu Bar** is off.
- Loads profiles from `~/Library/Application Support/Hostess/Profiles`.
- Copies existing legacy HostMask profiles into the Hostess profile folder on first launch.
- Creates `Default.hst` from the current `/etc/hosts` when no profiles exist.
- Imports arbitrary hosts files with `.hst`, `.hosts`, or `.txt` extensions.
- Edits profiles in a built-in editor with New, Rename, Duplicate, Delete, Save, and Apply.
- Supports standard macOS editing shortcuts: Command-C/V/X/A for copy, paste, cut, and select all; Command-Z and Shift-Command-Z for undo and redo.
- Applies the selected profile by replacing `/etc/hosts` with that profile's content.
- Accepts profiles up to 512 KiB when applying changes; rejects empty content and null bytes.
- Uses administrator approval to write the selected contents through protected staging, then flushes DNS cache.
- Apple Development and Developer ID signed builds can enable passwordless switching through macOS Service Management. The app and helper verify each other's signing identity, and the helper permits only the administrator-enrolled user account.
- Can disable passwordless switching from the menu. Disable it before replacing a signed app manually.

## Security and sharing

See [SECURITY.md](SECURITY.md) for the privilege model, upgrade steps, and remaining release requirements. Keep real profiles, build output, signing keys, and credentials out of the repository. Use example hostnames in screenshots.

## License

[MIT](LICENSE) © 2026 Katrina Tantay.
