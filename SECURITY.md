# Security

Hostess replaces `/etc/hosts` and therefore needs administrator authority. Profile contents can redirect hostname resolution. Review imported profiles before applying them.

## Administrator approval

The public unnotarized ZIP and local ad hoc builds use macOS administrator authorization for profile changes. The selected UTF-8 contents are encoded as data in the authorization request. The privileged operation creates its own staging directory under `/private/etc`, writes fixed permissions, and atomically replaces the hosts file. It does not read a temporary pathname supplied by the user process.

Both write paths reject empty content, null bytes, and profiles larger than 512 KiB. This limit keeps administrator requests within the tested command transport size.

## Passwordless switching

Passwordless switching requires an Apple Development signed personal build or a Developer ID signed build, with Hardened Runtime. The public ad hoc ZIP cannot enable this helper. The helper is registered through `SMAppService`, so macOS verifies the bundled executable and requires administrator approval in System Settings. Hostess never copies a user-writable executable into a privileged location itself.

During setup, administrator authorization records the current user's numeric ID in a root-owned configuration file. The helper requires that ID for every write. Both sides of the XPC connection require the expected identifier, the same signing authority type, and the same trusted Apple team. Personal builds additionally require the exact same Apple Development certificate. Builds with debugging or code-injection entitlements and ad hoc signatures are rejected. Replacing an expired development certificate requires rebuilding both the app and helper.

The configuration is read through one descriptor. Symlinks, non-root ownership, and group or world write permissions are rejected. Hosts writes use root-created staging and atomic replacement.

## Upgrade from Hostess 0.1

The old `app.hostess.Hostess.Helper` service accepted unrelated programs running under the installing account. Version 0.2 uses a different service, `app.hostess.Hostess.ManagedHelper`, and never sends profile contents to the old one.

Replacing the app does not remove the old service. Use **Remove Old Helper** in Hostess, or run `sudo Scripts/uninstall_helper.sh` from the source directory. The cleanup disables and stops the old launchd service, then removes its three fixed system files. It leaves `/etc/hosts` and saved profiles intact. Until this cleanup succeeds, the old service remains a security risk.

## Removal and updates

Choose **Disable Passwordless Switching** before manually replacing or removing a signed app. This unregisters the managed service. The Homebrew cask unregisters it before removal, then removes helper configuration and any remaining legacy installation. Ordinary uninstall preserves profiles; Homebrew's explicit zap operation removes user data.

For non-Homebrew removal, the service can also be unregistered by running the installed app's executable with `--unregister-helper` as the current user. Do not run the app executable as root. The inactive enrollment file at `/Library/Preferences/app.hostess.Hostess.ManagedHelper.plist` can be removed separately with administrator privileges.

## Releases

`Scripts/package_app.sh` creates the public unnotarized ZIP and a SHA-256 checksum. It uses an ad hoc signature, which provides no verified developer identity. The archive name includes the version, architecture, and `unnotarized` label. The current download supports Apple Silicon and macOS 13 or later.

macOS normally blocks this download on first launch. Users can approve it through **System Settings → Privacy & Security → Open Anyway**, where permitted. See [Apple's installation guidance](https://support.apple.com/en-us/102445) and the [download instructions](README.md#download).

`Scripts/build_app.sh` produces a local ad hoc build by default and stops on signing errors. For distribution that passes Gatekeeper's normal checks, `Scripts/release_app.sh` requires a Developer ID identity and an existing notarization keychain profile. It creates a release archive only after notarization is accepted, the ticket is stapled and validated, and Gatekeeper accepts the app.

Passwordless switching has been verified on the maintainer's Mac with an Apple Development signed personal build. Installation and privileged writes from the downloaded ZIP on another Mac remain unverified. The automated tests verify rejected impostor signatures and safe command behavior using scratch files. They do not perform administrator writes or notarization.

Keep real hosts profiles, private screenshots, credentials, and signing keys out of public issues and repository files. This project has no telemetry, network client, or external Swift package dependencies.
