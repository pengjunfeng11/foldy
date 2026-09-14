#!/bin/bash
set -euo pipefail
if [[ $# -ne 2 ]]; then
  printf 'usage: %s compiled-helper output.pkg\n' "$0" >&2
  exit 2
fi
source_helper="$1"
output_pkg="$2"
script_dir="$(cd "$(dirname "$0")" && pwd)"
staging="$(mktemp -d /tmp/foldy-guardian-pkg.XXXXXX)"
trap 'rm -rf "$staging"' EXIT
mkdir -p "$staging/root/Library/PrivilegedHelperTools" "$staging/root/Library/LaunchDaemons" "$staging/scripts"
install -m 755 "$source_helper" "$staging/root/Library/PrivilegedHelperTools/app.local.foldy.guardian"
codesign --verify --strict "$staging/root/Library/PrivilegedHelperTools/app.local.foldy.guardian"
cat > "$staging/root/Library/LaunchDaemons/app.local.foldy.guardian.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>app.local.foldy.guardian</string>
<key>ProgramArguments</key><array><string>/Library/PrivilegedHelperTools/app.local.foldy.guardian</string></array>
<key>MachServices</key><dict><key>app.local.foldy.guardian</key><true/></dict>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><true/>
<key>ProcessType</key><string>Background</string>
<key>ExitTimeOut</key><integer>30</integer>
</dict></plist>
PLIST
chmod 644 "$staging/root/Library/LaunchDaemons/app.local.foldy.guardian.plist"
install -m 755 "$script_dir/guardian-pkg/preinstall" "$staging/scripts/preinstall"
pkgbuild --root "$staging/root" --scripts "$staging/scripts" --identifier app.local.foldy.guardian.pkg --version 1 --ownership recommended --install-location / "$output_pkg"
