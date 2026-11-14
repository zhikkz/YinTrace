const _flag = String.fromEnvironment('YINTRACE_TEST_BUILD');

/// Test builds (`--dart-define=YINTRACE_TEST_BUILD=true`; CI packages one as
/// YinTrace-test-unsigned.ipa) add tools for testers: 设置 → 测试版 with
/// 性能测试 and 只用备用线路重新下载模型, and the model download shows which
/// route it uses. Release builds are made without the define: none of this
/// is compiled into them, and the download switches routes silently.
const isTestBuild = _flag == 'true' || _flag == '1';
