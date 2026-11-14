import 'package:yintrace/src/benchmark/device_benchmark.dart';

/// A report shaped like a finished run on a phone (made-up numbers).
Map<String, Object?> sampleReport() => {
  'version': benchmarkReportVersion,
  'app_version': '1.0.0',
  'options': {'song_seconds': 240, 'quick': false},
  'device': {
    'model': 'iPhone15,2',
    'os': 'Version 18.1 (Build 22B83)',
    'cores': 6,
    'memory_gb': 5.6,
    'available_memory_mb_at_start': 2950.0,
    'thermal_at_start': 'nominal',
  },
  'started_at': '2026-11-14T20:31:05.000',
  'finished_at': '2026-11-14T20:55:40.000',
  'done_steps': ['完整导入 4 分钟的合成歌曲'],
  'import': {
    'song_seconds': 240,
    'total_s': 312.4,
    'realtime_factor': 1.30,
    'vr': '6_HP-Karaoke-UVR（窗口 512）',
    'peak_footprint_mb': 1210.0,
    'thermal': 'fair',
    'stages_s': {'解码音频': 1.2, '分离人声': 150.3},
    'estimate_error_s': {'25%': 12.0, '50%': -3.0, '75%': null},
  },
  'models': [
    {'model': benchMdx, 'provider': 'CPU 4 线程', 'load_s': 0.8, 'first_run_s': 2.1, 'run_s': 1.9, 'thermal': 'fair'},
    {'model': benchMdx, 'provider': 'CPU 2 线程', 'load_s': 0.7, 'first_run_s': 3.1, 'run_s': 3.0},
    {
      'model': benchMdxStatic,
      'provider': 'Core ML MLProgram 全部单元',
      'load_s': 25.0,
      'first_run_s': 0.9,
      'run_s': 0.5,
      'snr_vs_cpu_db': 61.2,
    },
    {
      'model': benchMdxStatic,
      'provider': 'Core ML NeuralNetwork 全部单元',
      'load_s': 30.0,
      'first_run_s': 0.4,
      'run_s': 0.3,
      'snr_vs_cpu_db': 12.0, // fast but wrong: must not win
    },
    {'model': benchVr, 'provider': 'CPU 4 线程', 'load_s': 0.5, 'first_run_s': 2.4, 'run_s': 2.2},
    {
      'model': benchVr,
      'provider': 'Core ML MLProgram CPU+GPU',
      'error': 'OrtException | CoreML: unsupported op',
      'thermal': 'serious',
    },
  ],
};
