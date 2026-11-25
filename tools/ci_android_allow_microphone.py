#!/usr/bin/env python3
"""Taps "Allow" on Android's microphone prompt during the emulator smoke test.

Watches the focused window until the permission controller's prompt comes up
(integration_test/android_smoke_test.dart asks for the microphone), finds its
allow button with uiautomator and taps it. CI only (see the android job in
.github/workflows/ci.yml).
"""
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

PROMPT = "GrantPermissionsActivity"
# "While using the app" on Android 11+, "Allow" before.
BUTTONS = ("permission_allow_foreground_only_button", "permission_allow_button")


def adb(*args, timeout=30):
    try:
        return subprocess.run(["adb", *args], capture_output=True, text=True, timeout=timeout).stdout
    except subprocess.TimeoutExpired:
        return ""


def prompt_shown():
    return any(PROMPT in line for line in adb("shell", "dumpsys", "window", "windows").splitlines()
               if "mCurrentFocus" in line or "mFocusedApp" in line)


def find_button():
    dump = adb("exec-out", "uiautomator", "dump", "/dev/tty")
    start = dump.find("<?xml")
    end = dump.rfind("</hierarchy>")
    if start < 0 or end < 0:
        return None
    try:
        root = ET.fromstring(dump[start:end + len("</hierarchy>")])
    except ET.ParseError:
        return None
    for wanted in BUTTONS:
        for node in root.iter("node"):
            if node.get("resource-id", "").endswith(wanted):
                x1, y1, x2, y2 = map(int, re.findall(r"\d+", node.get("bounds", "")))
                return (x1 + x2) // 2, (y1 + y2) // 2
    return None


def main():
    deadline = time.time() + 1500
    print("waiting for the microphone prompt", flush=True)
    turn = 0
    while time.time() < deadline:
        turn += 1
        # Look at the screen itself every 10 s too, should dumpsys word it differently.
        if prompt_shown() or turn % 10 == 0:
            button = find_button()
            if button:
                adb("shell", "input", "tap", str(button[0]), str(button[1]))
                print(f"tapped allow at {button}", flush=True)
                return 0
        time.sleep(1)
    print("the microphone prompt never came up", flush=True)
    return 1


if __name__ == "__main__":
    sys.exit(main())
