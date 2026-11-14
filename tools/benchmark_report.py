#!/usr/bin/env python3
"""Prints the device benchmark's report (written by the app's own code,
lib/src/benchmark/benchmark_report.dart) from the driver's JSON
(build/integration_response_data.json), and writes it as Markdown when a
second path is given. Standard library only.

    python3 tools/benchmark_report.py build/integration_response_data.json build/device-benchmark.md
"""
import json
import sys
from pathlib import Path


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    data = json.loads(Path(sys.argv[1]).read_text())
    text = data.get('markdown')
    if not text:
        sys.exit(f'{sys.argv[1]} has no report (did the benchmark start?)')
    print(text)
    if len(sys.argv) > 2:
        Path(sys.argv[2]).write_text(text + '\n')
        print(f'\n已写入 {sys.argv[2]}')


if __name__ == '__main__':
    main()
