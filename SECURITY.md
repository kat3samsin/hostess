# Security

Hostess replaces `/etc/hosts` and therefore needs administrator authority. Profile contents can redirect hostname resolution. Review imported profiles before applying them.

## Passwordless switching

On first launch, Hostess offers to enable passwordless switching. One administrator approval installs a root-owned helper for the current user and the exact app build. Later profile changes use that helper without another password prompt. Each app update needs a new setup approval because the app's code hash changes.

The Homebrew build uses the `app.hostess.Hostess.PinnedHelper` launchd service. Setup records the current user's numeric ID and the app and helper code hashes in a root-owned configuration file. The helper accepts connections only from the approved Hostess build and checks the enrolled user before each operation. The app checks the helper's code hash and completes a harmless handshake before sending profile contents.

Both executables use Hardened Runtime. Code-signing requirements reject debugging and code-injection entitlements. Ad hoc signatures identify the approved code, but they do not verify a developer's identity. Setup does not give the user account general write access to `/etc/hosts`.

The app binds the bundled helper's code hash and SHA-256 digest to its own signed metadata. Setup copies that helper into root-owned staging and verifies it before installing or running it. It reads only a regular file, caps the copy at 64 MiB, and leaves source metadata behind. Installation rejects unexpected directory permissions, access grants, and symlinks. The helper reads its configuration through one descriptor and rejects symlinks, non-root ownership, and group or world write permissions.

One user can be enrolled at a time. Enabling passwordless switching from another account replaces the previous enrollment.

### Existing personal signed builds

Existing personal signed builds retain their `SMAppService` helper, `app.hostess.Hostess.ManagedHelper`. Both sides require the expected identifier, signing authority type, and trusted Apple team. Apple Development builds also require the exact same certificate. The helper checks the enrolled user's numeric ID before every write. Replacing an expired development certificate requires rebuilding both the app and helper.

## Administrator approval for each change

Choose **Not Now** during setup, or **Disable Passwordless Switching** from the menu, to require administrator approval for each profile change. Disabling the Homebrew helper also requires administrator approval so Hostess can stop and remove it.

Without the helper, the selected UTF-8 contents are encoded as data in the authorization request. The privileged operation creates its own staging directory under `/private/etc`, writes fixed permissions, and atomically replaces the hosts file. It does not read a temporary pathname supplied by the user process.

Both write paths use root-created staging and atomic replacement. They reject empty content, null bytes, and profiles larger than 512 KiB. This limit keeps administrator requests within the tested command transport size.

## Upgrade from Hostess 0.1

The old `app.hostess.Hostess.Helper` service accepted unrelated programs running under the installing account. Current versions use separate services and never send profile contents to the old one.

Replacing the app does not remove the old service. Use **Remove Old Helper** in Hostess, or run `sudo Scripts/uninstall_helper.sh` from the source directory. The cleanup disables and stops the old launchd service, then removes its three fixed system files. It leaves `/etc/hosts` and saved profiles intact. Until this cleanup succeeds, the old service remains a security risk.

## Removal and updates

After an update, enable passwordless switching again when Hostess prompts for setup. The previous enrollment cannot authorize the new app build. If you skip setup, profile changes require administrator approval.

Choose **Disable Passwordless Switching** before manually removing an app. The Homebrew cask unregisters any personal signed helper, then stops and removes the Homebrew helper and any remaining legacy installation. Cleanup removes their fixed configuration files. Ordinary uninstall preserves profiles and the current hosts file. Homebrew's explicit zap operation removes user data.

For recovery from a personal signed installation, run the installed app's executable with `--unregister-helper` as the current user. That command unregisters only the managed helper. Do not run the app executable as root. The inactive enrollment file at `/Library/Preferences/app.hostess.Hostess.ManagedHelper.plist` can be removed separately with administrator privileges.

## Releases

`Scripts/package_app.sh` creates the archive used by Homebrew and a SHA-256 checksum. It uses an ad hoc signature, which provides no verified developer identity. The archive name includes the version, architecture, and `unnotarized` label. The current Homebrew release supports Apple Silicon and macOS 13 or later. Its GitHub release assets remain available because the cask downloads and verifies that archive.

macOS normally blocks this app on first launch. Users can approve it through **System Settings → Privacy & Security → Open Anyway**, where permitted. See [Apple's installation guidance](https://support.apple.com/en-us/102445) and the [Homebrew installation instructions](README.md#install-with-homebrew).

`Scripts/build_app.sh` produces a local ad hoc build by default and stops on signing errors. Public releases use `Scripts/package_app.sh` and the project's Homebrew tap.

Administrator installation, the running root helper, and enrollment for a rebuilt ad hoc app have been verified on the maintainer's Mac. The maintainer has also confirmed passwordless profile switching with this build. A complete Homebrew installation, update, and removal check on a disposable Mac remains unverified. Automated checks use scratch files and test code-signing requirements. They do not establish that privileged writes work on a fresh Mac.

Keep real hosts profiles, private screenshots, credentials, and signing keys out of public issues and repository files. This project has no telemetry, network client, or external Swift package dependencies.
