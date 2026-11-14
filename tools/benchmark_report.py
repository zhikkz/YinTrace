#!/usr/bin/env python3
"""Turns the device benchmark's JSON (build/integration_response_data.json)
into a readable report: printed, and written as Markdown when a second path
is given. Standard library only.

    python3 tools/benchmark_report.py build/integration_response_data.json build/device-benchmark.md
"""
import json
import sys
from pathlib import Path

# Core ML may change the numbers a little (it can compute in 16-bit floats).
# Above this difference-to-CPU ratio the separation stays practically the same.
SAFE_SNR_DB = 40.0


def num(value, digits=2, suffix=''):
    if value is None:
        return '–'
    if isinstance(value, float):
        return f'{value:.{digits}f}{suffix}'
    return f'{value}{suffix}'


def table(head, rows):
    out = ['| ' + ' | '.join(head) + ' |', '|' + '|'.join('---' for _ in head) + '|']
    out += ['| ' + ' | '.join(str(c) for c in row) + ' |' for row in rows]
    return out


def report(data):
    lines = ['# YinTrace 真机测速报告', '']
    dev = data.get('device', {})
    lines += [
        f"- 系统：{dev.get('os', '–')}",
        f"- CPU 核数：{dev.get('cores', '–')}",
        f"- 开始时系统允许 App 再用的内存：{num(dev.get('available_memory_mb_at_start'), 0, ' MB')}"
        + ('（模拟器不报告）' if dev.get('available_memory_mb_at_start') is None else ''),
    ]
    if dev.get('quick'):
        lines.append('- 快速模式：只测了部分设置，每种只跑一次')
    lines.append('')

    models = data.get('models', [])
    base = {}
    for m in models:
        if m.get('provider') == 'CPU 4 线程' and m.get('run_s'):
            base.setdefault(m['model'], m['run_s'])
    rows = []
    for m in models:
        cpu4 = base.get(m['model']) or base.get('MDX T=128' if m['model'].startswith('MDX') else m['model'])
        speedup = num(cpu4 / m['run_s'], 2, ' 倍') if cpu4 and m.get('run_s') else '–'
        rows.append([
            m['model'], m['provider'],
            num(m.get('load_s'), 1, ' 秒'), num(m.get('first_run_s'), 2, ' 秒'), num(m.get('run_s'), 3, ' 秒'),
            speedup, num(m.get('snr_vs_cpu_db'), 1, ' dB'), num(m.get('peak_footprint_mb'), 0, ' MB'),
            m.get('error') or '',
        ])
    lines += ['## 单个模型', '']
    lines += table(['模型', '计算方式', '加载', '第一次推理', '每次推理', '相对 CPU 4 线程', '与 CPU 差值比', '内存峰值增量', '错误'], rows)
    lines += [
        '',
        '“加载”包括 Core ML 编译模型的时间（每次导入都要加载一次，用缓存后只有第一次慢）。'
        '“与 CPU 差值比”越高越接近 CPU 的结果，'
        f'{SAFE_SNR_DB:.0f} dB 以上分离结果实际上相同。内存峰值增量是 iOS 报告的 App 占用增加量。',
        '',
    ]

    lines += ['## 结论', '']
    for name in dict.fromkeys(m['model'] for m in models):
        candidates = [m for m in models if m['model'] == name and m.get('run_s') and not m.get('error')
                      and (m['provider'].startswith('CPU') or (m.get('snr_vs_cpu_db') or 0) >= SAFE_SNR_DB)
                      and '缓存' not in m['provider']]
        if not candidates:
            continue
        best = min(candidates, key=lambda m: m['run_s'])
        cpu4 = base.get(name) or (base.get('MDX T=128') if name.startswith('MDX') else None)
        if best['provider'] == 'CPU 4 线程':
            lines.append(f'- {name}：仍是「CPU 4 线程」最快（没有更快且结果足够接近的 Core ML 设置），'
                         f'每次 {best["run_s"]:.3f} 秒。')
            continue
        gain = f'，是 CPU 4 线程的 {cpu4 / best["run_s"]:.2f} 倍速度' if cpu4 else ''
        lines.append(f'- {name}：最快且结果可靠的是「{best["provider"]}」，每次 {best["run_s"]:.3f} 秒{gain}。')
    lines.append('')

    imp = data.get('import')
    if imp:
        lines += ['## 完整导入（App 实际的导入流程，CPU）', '']
        stages = imp.get('stages_s') or {}
        est = imp.get('estimate_error_s') or {}
        lines += table(['项目', '结果'], [
            ['合成歌曲时长', num(imp.get('song_seconds'), 0, ' 秒')],
            ['总耗时', num(imp.get('total_s'), 1, ' 秒')],
            ['耗时 / 歌曲时长', num(imp.get('realtime_factor'), 2, ' 倍')],
            ['去和声窗口', imp.get('vr') or '6_HP-Karaoke-UVR（512）'],
            ['内存峰值增量', num(imp.get('peak_footprint_mb'), 0, ' MB')],
            *[[f'阶段：{k}', num(v, 1, ' 秒')] for k, v in stages.items()],
            *[[f'“预计还需”在 {k} 处的误差', num(v, 0, ' 秒')] for k, v in est.items()],
            *([['错误', imp['error']]] if imp.get('error') else []),
        ])
        lines += ['', '误差为正：预计的时间比实际短。', '']
    return '\n'.join(lines)


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    data = json.loads(Path(sys.argv[1]).read_text())
    text = report(data)
    print(text)
    if len(sys.argv) > 2:
        Path(sys.argv[2]).write_text(text + '\n')
        print(f'\n已写入 {sys.argv[2]}')


if __name__ == '__main__':
    main()
