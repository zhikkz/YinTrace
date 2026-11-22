#!/usr/bin/env python3
"""Check that the unsigned iOS distribution carries the pinned notices."""

import argparse
import gzip
import hashlib
import re
from pathlib import Path
from zipfile import ZipFile


ASSETS = 'Payload/Runner.app/Frameworks/App.framework/flutter_assets/'
LICENSES = {
    'onnxruntime-1.28.0-LICENSE.txt': '2f07c72751aed99790b8a4869cf2311df85a860b22ded05fa22803587a48922c',
    'onnxruntime-1.28.0-ThirdPartyNotices.txt': '0e07b95f3a8d6230037707c5c4a2b554d12c4cb67369669ac255635528ffcee2',
    'archive-4.7.1-LICENSE-other.md': 'b8861b258b8eedd1605f5203b0f51e8022c5c156cb97da1c465e4e355672738b',
    'CC-BY-SA-4.0.txt': '28a9529c7d0bb4dc51f4bf5c116a3d16ef247a052f7591466768ddf563fd1cf5',
    'Unicode-3.0.txt': 'e7a93b009565cfce55919a381437ac4db883e9da2126fa28b91d12732bc53d96',
    'cmudict-LICENSE.txt': 'bd4ce8e44170a5f9f481310ca85c51de3c4f851a65e679b40e603b143bd3542a',
}


def verify_versions(pub_lock, pod_lock):
    archive = re.search(r'^  archive:\n((?:    .*\n)+)', pub_lock.read_text(), re.MULTILINE)
    if archive is None or not re.search(r'^    version: ["\']?4\.7\.1["\']?$', archive.group(1), re.MULTILINE):
        raise SystemExit('Update the archive notices for the version in pubspec.lock.')
    pods = pod_lock.read_text()
    for name in ('onnxruntime-c', 'onnxruntime-objc'):
        versions = set(re.findall(rf'^  - {name}(?:/Core)? \(([^)]*)\)(?::|$)', pods, re.MULTILINE))
        if versions != {'1.28.0'}:
            raise SystemExit(f'Update the ONNX Runtime notices for the version of {name} in Podfile.lock.')


def verify_package(path):
    with ZipFile(path) as ipa:
        def read(relative):
            try:
                return ipa.read(ASSETS + relative)
            except KeyError:
                raise SystemExit(f'File missing from IPA: {relative}') from None

        flutter_notices = gzip.decompress(read('NOTICES.Z'))
        for text in (b'GNU AFFERO GENERAL PUBLIC LICENSE', b'Version 3, 19 November 2007'):
            if text not in flutter_notices:
                raise SystemExit('Flutter NOTICES.Z is missing the AGPL v3.')
        for filename, expected in LICENSES.items():
            contents = read('assets/licenses/' + filename)
            if hashlib.sha256(contents).hexdigest() != expected:
                raise SystemExit(f'Bundled notice differs from upstream: {filename}')
        if b'KleidiAI' not in read('assets/licenses/onnxruntime-1.28.0-ThirdPartyNotices.txt'):
            raise SystemExit('Missing KleidiAI notice.')
        if b'Zstandard 1.5.7' not in read('assets/licenses/archive-4.7.1-LICENSE-other.md'):
            raise SystemExit('Missing Zstandard notice.')
        if b'CC BY-SA 4.0 International' not in read('assets/mandarin/cc-cedict-readings.tsv'):
            raise SystemExit('Missing CC-CEDICT attribution in the distributed table.')
    print('Verified AGPL v3, ONNX Runtime (KleidiAI), archive (Zstandard), and dictionary notices in the IPA.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('ipa', type=Path)
    parser.add_argument('--pub-lock', type=Path, default=Path('pubspec.lock'))
    parser.add_argument('--pod-lock', type=Path, default=Path('ios/Podfile.lock'))
    args = parser.parse_args()
    verify_versions(args.pub_lock, args.pod_lock)
    verify_package(args.ipa)


if __name__ == '__main__':
    main()
