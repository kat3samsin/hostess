cask "hostess" do
  version "0.2.0"
  sha256 "7d10a1fbd021a983cd3e05be2a2bd427f4b265354259da6e4d0330428b72f61e"

  url "https://github.com/kat3samsin/hostess/releases/download/v#{version}/Hostess-#{version}-arm64-unnotarized.zip"
  name "Hostess"
  desc "Menu bar app for switching hosts-file profiles"
  homepage "https://github.com/kat3samsin/hostess"

  depends_on arch: :arm64
  depends_on macos: :ventura

  app "Hostess.app"

  # Unregister through Service Management as the current user, before removing the app.
  uninstall_preflight do
    system_command "#{appdir}/Hostess.app/Contents/MacOS/Hostess",
                   args: ["--unregister-helper"],
                   sudo: false,
                   must_succeed: true
  end

  # Only system executables and fixed paths run with administrator privileges.
  uninstall quit: "app.hostess.Hostess",
            script: {
              executable: "/bin/sh",
              args: ["-c", <<~SH],
                set -eu
                /bin/launchctl disable system/app.hostess.Hostess.Helper
                if state=$(/bin/launchctl print system/app.hostess.Hostess.Helper 2>&1); then
                  /bin/launchctl bootout system/app.hostess.Hostess.Helper
                else
                  status=$?
                  if [ "$status" -ne 113 ]; then
                    printf '%s\\n' "$state" >&2
                    exit "$status"
                  fi
                fi
                /bin/rm -f \
                  /Library/LaunchDaemons/app.hostess.Hostess.Helper.plist \
                  /Library/PrivilegedHelperTools/app.hostess.Hostess.Helper \
                  /Library/Preferences/app.hostess.Hostess.Helper.plist \
                  /Library/Preferences/app.hostess.Hostess.ManagedHelper.plist
              SH
              sudo: true,
              must_succeed: true,
            }

  zap trash: [
    "~/Library/Application Support/Hostess",
    "~/Library/Preferences/app.hostess.Hostess.plist",
  ]

  caveats <<~EOS
    This download is ad hoc signed and not notarized.
    After the first blocked launch, allow Hostess in
    System Settings > Privacy & Security > Open Anyway.

    Profile changes in this release require administrator approval.
    Passwordless switching is unavailable in this build.
  EOS
end
