#!/usr/bin/env python3
"""Run with python3 Scripts/guardian-install-check.py; never installs or requests admin access."""
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile


def check():
    if os.geteuid() == 0:
        raise SystemExit("Run this check as an ordinary user, without sudo.")
    source = (Path(__file__).resolve().parents[1] / "Sources/TaskGuardian.swift").read_text()
    # Exercise the actual Swift shell construction and AppleScript escaping, using harmless stubs.
    block = 'let command = [' + source.split('let command = [', 1)[1].split('].joined(separator: "; ")', 1)[0] + '].joined(separator: "; ")'
    for old, new in [("Self.shellQuote", "quote"), ("GuardianPackage.sha256", "expected"),
                     ("GuardianPaths.helper", "helperPath"), ("Bundle.main.bundleURL.path", "appPath")]:
        block = block.replace(old, new)
    block = block.replace('"/usr/sbin/installer -pkg \\"$guardian_stage/Guardian.pkg\\" -target /"',
                          'quote(installerPath) + " -pkg \\"$guardian_stage/Guardian.pkg\\" -target /"')
    quote = next(line.strip() for line in source.splitlines() if "private static func shellQuote" in line)
    quote = quote.replace("private static func shellQuote", "func quote")
    script_line = next(line.strip() for line in source.splitlines() if line.strip().startswith('let script = "do shell script'))
    script_line = script_line.replace(' with administrator privileges"', '"')
    assert "/usr/sbin/installer" not in block and "GuardianPaths.helper" not in block
    assert "administrator privileges" not in script_line

    with tempfile.TemporaryDirectory(prefix="foldy-install-check-") as temporary:
        directory = Path(temporary)
        pkg = directory / 'pkg $dollar `tick` \'quote "double.pkg'
        app = directory / 'Foldy $dollar `tick` \'quote.app'
        marker, helper_marker, stage_marker = (directory / name for name in ["installed", "helper-called", "stage"])
        installer, helper = directory / "installer stub", directory / "helper stub"
        installer.write_text(
            '#!/bin/sh\nset -eu\n[ "$1" = -pkg ]\n'
            '[ "$(/usr/bin/stat -f %Lp "$(/usr/bin/dirname "$2")")" = 700 ]\n'
            '/usr/bin/dirname "$2" > ' + shlex.quote(str(stage_marker)) + '\n'
            # A source replacement after the copy cannot alter the staged package.
            '/usr/bin/printf replaced > ' + shlex.quote(str(pkg)) + '\n'
            '/bin/cp "$2" ' + shlex.quote(str(marker)) + '\n')
        helper.write_text('#!/bin/sh\nset -eu\n[ "$1" = --install ]\n[ "$2" = ' + shlex.quote(str(app)) + ' ]\n'
                          '[ "$3" = ' + str(os.getuid()) + ' ]\n/bin/echo done > ' + shlex.quote(str(helper_marker)) + '\n')
        installer.chmod(0o700); helper.chmod(0o700)
        prefix = 'import Foundation\nimport Darwin\n' + quote + '\n'
        prefix += 'let pkg=URL(fileURLWithPath:' + json.dumps(str(pkg)) + ')\n'
        for name, value in [("appPath", str(app)), ("installerPath", str(installer)), ("helperPath", str(helper)),
                            ("expected", hashlib.sha256(b"approved payload").hexdigest())]:
            prefix += 'let ' + name + '=' + json.dumps(value) + '\n'
        probe, executable = directory / "probe.swift", directory / "probe"
        probe.write_text(prefix + 'let normalizeOnInstall=false\n' + block + '\n' + script_line + '\nprint(script)\n')
        subprocess.run(["xcrun", "swiftc", str(probe), "-o", str(executable)], check=True, timeout=60)
        script = subprocess.check_output([str(executable)], text=True, timeout=5).strip()
        assert "administrator privileges" not in script and "/usr/sbin/installer" not in script
        pkg.write_bytes(b"approved payload")
        valid = subprocess.run(["/usr/bin/osascript", "-e", script], text=True, capture_output=True, timeout=10)
        assert valid.returncode == 0, valid.stderr
        assert marker.read_bytes() == b"approved payload" and helper_marker.exists()
        assert pkg.read_bytes() == b"replaced" and not Path(stage_marker.read_text().strip()).exists()
        marker.unlink(); helper_marker.unlink()
        invalid = subprocess.run(["/usr/bin/osascript", "-e", script], text=True, capture_output=True, timeout=10)
        assert invalid.returncode != 0 and not marker.exists() and not helper_marker.exists(), invalid.stderr
    print("guardian install check passed: complex paths, 0700 staging, source replacement isolation, digest rejection, cleanup; no admin access or installation")


if __name__ == "__main__":
    check()
