#!/usr/bin/env python3
"""Sample the host full-import test's app + ORT child RSS on Linux.

Set MODELS_DIR, REAL_IMPORT_AUDIO, REAL_IMPORT_LYRICS, YINTRACE_AUDIO_LIB and
PYTHON as for test/real_import_test.dart. The test runner/compiler are excluded:
this reports flutter_tester and its ORT children, not all developer tooling.
It is a 10 Hz host RSS measurement, not iPhone Physical Footprint.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import time


def processes():
    result = {}
    for path in Path('/proc').glob('[0-9]*'):
        try:
            stat = (path / 'stat').read_text().rsplit(')', 1)[1].split()
            parent = int(stat[1])
            args = (path / 'cmdline').read_bytes().split(b'\0')
            rss = next(int(line.split()[1]) * 1024 for line in (path / 'status').read_text().splitlines()
                       if line.startswith('VmRSS:'))
            result[int(path.name)] = (parent, args, rss)
        except (OSError, ValueError, StopIteration):
            pass  # child exited while sampled
    return result


def descendants(table, roots):
    found = set(roots)
    while True:
        new = {pid for pid, (parent, _, _) in table.items() if parent in found} - found
        if not new:
            return found
        found.update(new)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--flutter', default='flutter')
    ap.add_argument('--out', type=Path, default=Path('build/import-memory.json'))
    args = ap.parse_args()
    if sys.platform != 'linux':
        ap.error('Linux /proc is required; use Instruments on Apple devices')
    env = dict(os.environ, BOT='true', CI='true', FLUTTER_SUPPRESS_ANALYTICS='true', ORT_DISABLE_TELEMETRY='1')
    # Honour the same opt-out commands as interactive validation.
    subprocess.run([args.flutter, 'config', '--no-analytics'], env=env, check=True)
    dart = str(Path(args.flutter).with_name('dart')) if '/' in args.flutter else 'dart'
    subprocess.run([dart, '--disable-analytics'], env=env, check=True)
    started = time.monotonic()
    proc = subprocess.Popen([args.flutter, 'test', 'test/real_import_test.dart', '--reporter', 'expanded'], env=env)
    peak = {'total_bytes': 0, 'app_bytes': 0, 'ort_bytes': 0, 'elapsed_seconds': 0}
    samples = 0
    while proc.poll() is None:
        table = processes()
        children = descendants(table, {proc.pid})
        apps = {pid for pid in children if pid in table and table[pid][1]
                and Path(os.fsdecode(table[pid][1][0])).name == 'flutter_tester'}
        if apps:
            app_rss = sum(table[pid][2] for pid in apps)
            app_children = descendants(table, apps)
            ort_rss = sum(table[pid][2] for pid in app_children if pid in table
                          and any(b'ort_server.py' in arg for arg in table[pid][1]))
            samples += 1
            if app_rss + ort_rss > peak['total_bytes']:
                peak = dict(total_bytes=app_rss + ort_rss, app_bytes=app_rss, ort_bytes=ort_rss,
                            elapsed_seconds=time.monotonic() - started)
        time.sleep(0.1)
    report = dict(platform=sys.platform, interval_seconds=0.1, samples=samples, peak=peak,
                  elapsed_seconds=time.monotonic() - started, exit_code=proc.returncode)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report), flush=True)
    if not samples:
        sys.exit('no flutter_tester process sampled; do not interpret a zero peak as success')
    sys.exit(proc.returncode)


if __name__ == '__main__':
    main()
