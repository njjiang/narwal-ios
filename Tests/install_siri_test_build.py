#!/usr/bin/env python3
"""Install and immediately launch an intercepted Siri test build.

Fail before installation if the phone requires its passcode. Once installed,
launch immediately: leaving the phone at Home between these steps allows its
normal auto-lock timer to expire while other diagnostics are being prepared.
"""
import argparse
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--device", required=True)
    parser.add_argument("--exact-phrases", action="store_true", help="Allow a build intentionally made without flexible-matching assets")
    parser.add_argument("--diagnostic-string-probe", action="store_true", help="Allow only the isolated, uniquely named String-options probe")
    args = parser.parse_args()
    info = plistlib.loads((args.app / "Info.plist").read_bytes())
    bundle = info.get("CFBundleIdentifier")
    if bundle != "com.freo.personal.control":
        raise SystemExit("Expected the existing Narwal test target; no app was installed.")
    executable = args.app / info["CFBundleExecutable"]
    binaries = [executable, *args.app.glob("*.debug.dylib")]
    if not any(b"--freo-siri-routing-test" in file.read_bytes() for file in binaries if file.is_file()):
        raise SystemExit("Missing explicit robot-start interception support; no app was installed.")
    metadata = json.loads((args.app / "Metadata.appintents/extract.actionsdata").read_text())
    identifiers = {entry["actionIdentifier"] for entry in metadata["autoShortcuts"]}
    expected = {
        "VacuumRoomIntent", "MopRoomIntent",
        "VacuumAndMopRoomIntent", "VacuumThenMopRoomIntent",
        "PauseRobotIntent", "StopRobotIntent",
    }
    if args.diagnostic_string_probe:
        if identifiers != {"FreoStringRoomProbeIntent"} or info.get("CFBundleDisplayName") != "Freo Probe":
            raise SystemExit("Not the isolated String-options diagnostic; no app was installed.")
    elif identifiers != expected:
        raise SystemExit("Unexpected shortcut registrations; no app was installed.")
    language_asset = args.app / "Metadata.appintents/nlu/nlu.lzfse"
    if not args.exact_phrases and (not language_asset.is_file() or language_asset.stat().st_size == 0):
        raise SystemExit("Missing Siri language assets; no app was installed.")
    env = dict(os.environ)
    env.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
    base = ["xcrun", "devicectl", "device"]
    with tempfile.TemporaryDirectory(prefix="freo-test-lock-") as directory:
        output = Path(directory) / "lock.json"
        subprocess.run(base + ["info", "lockState", "--device", args.device,
                               "--json-output", str(output), "-q"], env=env, check=True)
        state = json.loads(output.read_text())["result"]
        if state.get("passcodeRequired") is not False:
            raise SystemExit("iPhone requires its passcode. Unlock it first; no app was installed.")
    subprocess.run(base + ["install", "app", "--device", args.device, str(args.app)],
                   env=env, check=True)
    subprocess.run(base + ["process", "launch", "--terminate-existing", "--timeout", "10",
                           "--device", args.device, bundle, "--freo-siri-routing-test"],
                   env=env, check=True)
    print("Installed and launched the Siri test build. Verify its interception banner before invoking Siri.")


if __name__ == "__main__":
    main()
