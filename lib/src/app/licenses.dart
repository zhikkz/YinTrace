import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Version shown in the app (kept in step with pubspec.yaml by a test).
const appVersion = '1.0.0';

/// YinTrace is free software under the GNU AGPL v3. The About page shows
/// these notices; the license text itself (the LICENSE file at the root of
/// the repository) is bundled by Flutter and appears on the in-app license
/// page under "yintrace".
const appCopyright = 'Copyright © 2026 zhikkz';
const appSourceUrl = 'https://github.com/zhikkz/YinTrace';

// Icon assets are original vectors rendered with development-only CairoSVG
// (LGPL-3.0-or-later); CairoSVG is not linked or distributed with the app.

/// Licenses of third-party work that is not a pub package (those are
/// collected by Flutter automatically). Shown by the in-app license page.
/// See also THIRD_PARTY_NOTICES.md at the root of the repository.
void registerThirdPartyLicenses() {
  LicenseRegistry.addLicense(() async* {
    final license = await rootBundle.loadString('assets/models/hubertfa-LICENSE.txt');
    yield LicenseEntryWithLineBreaks(const ['HuBERTFA AlignmentDecoder'], '''
YinTrace adapts the HuBERTFA v0.0.7 AlignmentDecoder to Dart.
https://github.com/wolfgitpr/HubertFA

$license''');
    for (final (name, file) in const [
      ('HuBERTFA v0.0.7 model and dictionary provenance', 'hubertfa-v0.0.7-provenance.txt'),
      ('CMUdict', 'cmudict-LICENSE.txt'),
      ('ONNX Runtime 1.28.0', 'onnxruntime-1.28.0-LICENSE.txt'),
      ('ONNX Runtime 1.28.0 third-party notices (including KleidiAI)', 'onnxruntime-1.28.0-ThirdPartyNotices.txt'),
      ('archive 4.7.1 third-party notices (including Zstandard)', 'archive-4.7.1-LICENSE-other.md'),
      ('Unicode Unihan 17.0.0', 'Unicode-3.0.txt'),
      ('phrase-pinyin-data (used by earlier versions)', 'phrase-pinyin-data-LICENSE.txt'),
    ]) {
      yield LicenseEntryWithLineBreaks([name], await rootBundle.loadString('assets/licenses/$file'));
    }
    final ccLicense = await rootBundle.loadString('assets/licenses/CC-BY-SA-4.0.txt');
    yield LicenseEntryWithLineBreaks(const ['CC-CEDICT'], '''
CC-CEDICT contributors, published by MDBG. Based on CEDICT, Copyright (C) 1997, 1998 Paul Andrew Denisowski.
https://www.mdbg.net/chinese/dictionary?page=cedict

YinTrace extracted Chinese headwords and toneless pronunciations for the reading and segmentation tables, and wrote er for independently timed 儿/兒. Both tables are available separately under CC BY-SA 4.0 International.
https://github.com/zhikkz/YinTrace/blob/main/assets/mandarin/cc-cedict-readings.tsv
https://github.com/zhikkz/YinTrace/blob/main/assets/mandarin/cc-cedict-words.tsv
https://creativecommons.org/licenses/by-sa/4.0/

$ccLicense''');
  });
  LicenseRegistry.addLicense(
    () => Stream.fromIterable([
      LicenseEntryWithLineBreaks(
        const ['Ultimate Vocal Remover GUI'],
        '''
YinTrace's vocal separation is a port of the MDX-Net and VR-architecture pre- and post-processing of Ultimate Vocal Remover GUI (https://github.com/Anjok07/ultimatevocalremovergui), and the graph of the harmony-removal network bundled with the app re-implements UVR's VR network definition.

The models UVR-MDX-NET-Voc_FT and 6_HP-Karaoke-UVR were trained and published by the UVR developers (Anjok07, aufr33). They are not part of this app: it downloads the original files on first use. The UVR authors ask applications that use their models to credit UVR and its developers.

${_mit('Copyright (c) 2022 Anjok07, Aufr33')}''',
      ),
      LicenseEntryWithLineBreaks(
        const ['vocal-remover (tsurumeso)'],
        '''
The VR architecture used by Ultimate Vocal Remover derives from https://github.com/tsurumeso/vocal-remover.

${_mit('Copyright (c) 2019 tsurumeso')}''',
      ),
      LicenseEntryWithLineBreaks(
        const ['MDX-Net (Kuielab, Woosung Choi)'],
        '''
The MDX-Net architecture and its demixing procedure derive from https://github.com/kuielab/mdx-net.

${_mit('Copyright (c) 2020 KINoAI')}''',
      ),
      LicenseEntryWithLineBreaks(
        const ['flutter_onnxruntime (YinTrace patch)'],
        '''
Vendored from flutter_onnxruntime 1.9.0 (https://github.com/masicai/flutter_onnxruntime).
YinTrace adds an Apple CPU arena option using ONNX Runtime's MIT-licensed internal session header.

${_mit('Copyright (c) MASIC AI')}''',
      ),
      const LicenseEntryWithLineBreaks(
        ['miniaudio'],
        '''
https://github.com/mackron/miniaudio - used under the MIT No Attribution license.

Copyright 2026 David Reid

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.''',
      ),
      LicenseEntryWithLineBreaks(
        const ['SwiftF0'],
        '''
YinTrace measures the original singer's pitch, when a song is imported, with SwiftF0 (https://github.com/lars76/swift-f0), a pitch estimation network by Lars Nieradzik: "SwiftF0: Fast and Accurate Monophonic Pitch Detection", arXiv:2508.18440, 2025.

The app bundles the model of swift-f0 0.3.0. Its weights are unchanged; its interface was adapted for the app (the pitch range fixed at 60 to 1400 Hz, the pitch output cast to 32-bit floats, the two outputs joined into one) by tools/build_pitch_model.py.

${_mit('Copyright (c) 2025-2026 Lars Nieradzik')}''',
      ),
    ]),
  );
}

String _mit(String copyright) =>
    '''
MIT License

$copyright

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.''';
