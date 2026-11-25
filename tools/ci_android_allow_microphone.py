#!/usr/bin/env python3
"""Taps "Allow" on Android's microphone prompt during the emulator smoke test.

Waits until integration_test/android_smoke_test.dart logs that it is asking,
then finds the permission controller's allow button with uiautomator and taps
it. CI only (see the android job in .github/workflows/ci.yml).
"""
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

MARKER = "ANDROID_SMOKE: asking for the microphone"
# "While using the app" on Android 11+, "Allow" before.
BUTTONS = ("permission_allow_foreground_only_button", "permission_allow_button")


def adb(*args, timeout=30):
    return subprocess.run(["adb", *args], capture_output=True, text=True, timeout=timeout)


def wait_for_marker(deadline):
    logcat = subprocess.Popen(["adb", "logcat", "-v", "brief", "flutter:I", "*:S"],
                              stdout=subprocess.PIPE, text=True)
    try:
        for line in logcat.stdout:
            if MARKER in line:
                return True
            if time.time() > deadline:
                return False
    finally:
        logcat.kill()
    return False


def find_button():
    dump = adb("exec-out", "uiautomator", "dump", "/dev/tty").stdout
    start = dump.find("<?xml")
    end = dump.rfind("</hierarchy>")
    if start < 0 or end < 0:
        return None
    root = ET.fromstring(dump[start:end + len("</hierarchy>")])
    for wanted in BUTTONS:
        for node in root.iter("node"):
            if node.get("resource-id", "").endswith(wanted):
                x1, y1, x2, y2 = map(int, re.findall(r"\d+", node.get("bounds", "")))
                return (x1 + x2) // 2, (y1 + y2) // 2
    return None


def main():
    deadline = time.time() + 1200
    adb("logcat", "-c")
    print("waiting for the smoke test to ask for the microphone", flush=True)
    if not wait_for_marker(deadline):
        print("the smoke test never asked", flush=True)
        return 1
    stop = time.time() + 60
    while time.time() < stop:
        try:
            button = find_button()
        except (ET.ParseError, subprocess.TimeoutExpired, ValueError):
            button = None
        if button:
            adb("shell", "input", "tap", str(button[0]), str(button[1]))
            print(f"tapped allow at {button}", flush=True)
            return 0
        time.sleep(1)
    print("no allow button on screen", flush=True)
    return 1


if __name__ == "__main__":
    sys.exit(main())
