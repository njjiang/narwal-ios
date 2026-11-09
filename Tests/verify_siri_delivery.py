#!/usr/bin/env python3
"""Verify a fresh Siri delivery from the app's intercepted execution trace.

XCTest's legacy Siri activation wait is unreliable with Siri AI. Its exit code
is not proof of delivery. Require the actual fixed-mode intent entry and its
validated, intercepted start result, both newer than the test's start time.
"""
import argparse
import json
from pathlib import Path
import re

TITLES = {"vacuum": "Vacuum", "mop": "Mop", "vacuumMop": "Vacuum & mop",
          "vacuumThenMop": "Vacuum, then mop"}
FOUNDATION_EPOCH = 978307200


def verify(entries: list, mode: str, room: str, after: float) -> bool:
    fresh = [entry for entry in entries if isinstance(entry, dict)
             and isinstance(entry.get("date"), (int, float))
             and entry["date"] + FOUNDATION_EPOCH >= after]
    entered = [entry for entry in fresh if entry.get("stage") == "mode command perform"]
    completed = [entry for entry in fresh if entry.get("stage") == "routing test result"]
    if len(entered) != 1 or len(completed) != 1:
        return False
    if entered[0].get("detail") != f"{mode} / {room}":
        return False
    elapsed = completed[0]["date"] - entered[0]["date"]
    if not 0 <= elapsed <= 15:
        return False
    match = re.fullmatch(r"Siri routing test [1-9][0-9]*: (.*)", completed[0].get("detail", ""))
    return bool(match and match[1] == f"{TITLES[mode]} in {room}.")



def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("trace", type=Path)
    parser.add_argument("--mode", choices=TITLES, required=True)
    parser.add_argument("--room", required=True)
    parser.add_argument("--after", type=float, required=True, help="Test start, Unix seconds")
    args = parser.parse_args()
    entries = json.loads(args.trace.read_text())
    if not isinstance(entries, list) or not verify(entries, args.mode, args.room, args.after):
        raise SystemExit("NOT VERIFIED: no fresh matching intent entry and intercepted result.")
    print(f"Verified Siri delivery: {TITLES[args.mode]} in {args.room}. Robot start was intercepted.")


if __name__ == "__main__":
    main()
