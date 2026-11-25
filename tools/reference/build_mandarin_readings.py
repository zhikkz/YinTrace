#!/usr/bin/env python3
"""Build the Mandarin tables from Unihan 17.0.0 and CC-CEDICT.

Usage: python tools/reference/build_mandarin_readings.py Unihan.zip cedict.zip
The input checksums are recorded in THIRD_PARTY_NOTICES.md.
"""

import argparse
import re
import unicodedata
from collections import defaultdict
from hashlib import file_digest
from pathlib import Path
from zipfile import ZipFile


ROOT = Path(__file__).resolve().parents[2]
DESTINATION = ROOT / 'assets/mandarin'
SYLLABLE = re.compile(r'[a-z]+')
ENTRY = re.compile(r'(\S+) (\S+) \[([^\[\]]+)\] /')
IDEOGRAPH = re.compile(r'[〇\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff\U00020000-\U0002ceaf]+')
# Prefer the adjective for isolated 長/长. CC-CEDICT supplies contextual readings like 長大.
ISOLATED_READINGS = {'長': 'chang', '长': 'chang'}


def syllable(value):
    plain = unicodedata.normalize('NFD', value.lower().rstrip('012345').replace('u:', 'ü'))
    plain = plain.replace('u\u0308', 'v')
    return ''.join(char for char in plain if not unicodedata.combining(char))


def unihan_rows(archive, filename, field):
    for line in archive.read(filename).decode().splitlines():
        if line.startswith('U+'):
            point, property_name, value = line.split('\t')
            if property_name == field:
                yield chr(int(point[2:], 16)), value


def read_unihan(path):
    readings = {}
    simplified = {}
    with ZipFile(path) as archive:
        for char, value in unihan_rows(archive, 'Unihan_Readings.txt', 'kMandarin'):
            candidates = dict.fromkeys(syllable(reading) for reading in value.split())
            if char in ISOLATED_READINGS:
                candidates = dict.fromkeys([ISOLATED_READINGS[char], *candidates])
            readings[char] = tuple(reading for reading in candidates if SYLLABLE.fullmatch(reading))
        for char, variants in unihan_rows(archive, 'Unihan_Variants.txt', 'kSimplifiedVariant'):
            if ' ' not in variants:
                simplified[char] = chr(int(variants[2:], 16))
    return readings, simplified


def read_cedict(path, characters):
    by_word = defaultdict(set)
    with ZipFile(path) as archive:
        lines = archive.read('cedict_ts.u8').decode('utf-8-sig').splitlines()
    date = next(line.removeprefix('#! date=') for line in lines if line.startswith('#! date='))
    for line in lines:
        entry = ENTRY.match(line)
        if entry is None:
            continue
        traditional, simplified, pinyin = entry.groups()
        reading = tuple(syllable(value) for value in pinyin.split())
        if not all(SYLLABLE.fullmatch(value) for value in reading):
            continue
        for word in {traditional, simplified}:
            if len(word) == len(reading) and IDEOGRAPH.fullmatch(word):
                by_word[word].add(reading)

    rows = []
    for word, candidates in sorted(by_word.items()):
        if len(word) == 1:
            additional = sorted({reading[0] for reading in candidates} - set(characters.get(word, ())))
            if additional:
                rows.append(f'{word}\t{" ".join(additional)}')
        elif len(candidates) == 1:
            reading, = candidates
            defaults = tuple(next(iter(characters.get(char, ())), '') for char in word)
            if reading != defaults:
                rows.append(f'{word}\t{" ".join(reading)}')
    return date, rows


def write_unihan(readings, simplified):
    rows = [
        '# Unicode Unihan 17.0.0, kMandarin and kSimplifiedVariant',
        '# Copyright © Unicode, Inc.  https://www.unicode.org/license.txt',
        '# Character, readings in priority order, optional unambiguous simplified variant (TSV).',
        '# YinTrace prefers chang for isolated 長 and 长.',
    ]
    for char in sorted(readings.keys() | simplified.keys()):
        values = ' '.join(readings.get(char, ()))
        variant = f'\t{simplified[char]}' if char in simplified else ''
        rows.append(f'{char}\t{values}{variant}')
    (DESTINATION / 'unihan-readings.tsv').write_text('\n'.join(rows) + '\n', encoding='utf-8', newline='\n')


def write_cedict(date, sha256, rows):
    notice = f'''# Adapted from CC-CEDICT contributors, published by MDBG, snapshot {date}.
# Referenced work: CEDICT, Copyright (C) 1997, 1998 Paul Andrew Denisowski.
# Source: https://www.mdbg.net/chinese/dictionary?page=cedict
# Source ZIP SHA-256: {sha256}
# Changes: extracted Chinese headwords and pronunciations, removed tones and definitions,
# retained additional single-character readings and unambiguous phrases requiring context.
# CC BY-SA 4.0 International: https://creativecommons.org/licenses/by-sa/4.0/
'''
    (DESTINATION / 'cc-cedict-readings.tsv').write_text(notice + '\n'.join(rows) + '\n', encoding='utf-8', newline='\n')


def write_onsets(readings):
    # Preserve the GB2312 coverage and onset rules of the fallback aligner.
    unvoiced, voiced = [], []
    for high in range(0xB0, 0xF8):
        for low in range(0xA1, 0xFF):
            try:
                char = bytes((high, low)).decode('gb2312')
            except UnicodeDecodeError:
                continue
            first = next(iter(readings.get(char, ())), '')[:1]
            if first and first in 'bpfdtgkhjqxzcs':
                unvoiced.append(char)
            elif first and first in 'mnlr':
                voiced.append(char)

    rows = ['// Generated by tools/reference/build_mandarin_readings.py from Unicode Unihan 17.0.0.',
            '// Unicode License v3: https://www.unicode.org/license.txt', '']
    for name, chars in [('unvoicedMandarinOnsets', unvoiced), ('voicedMandarinOnsets', voiced)]:
        rows.append(f'const {name} =')
        for start in range(0, len(chars), 60):
            chunk = ''.join(chars[start:start + 60])
            end = ';' if start + 60 >= len(chars) else ''
            rows.append(f"    '{chunk}'{end}")
        rows.append('')
    (ROOT / 'lib/src/analysis/unihan_onsets.dart').write_text('\n'.join(rows), encoding='utf-8', newline='\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('unihan')
    parser.add_argument('cedict')
    args = parser.parse_args()
    readings, simplified = read_unihan(args.unihan)
    date, cedict = read_cedict(args.cedict, readings)
    write_unihan(readings, simplified)
    with open(args.cedict, 'rb') as archive:
        write_cedict(date, file_digest(archive, 'sha256').hexdigest(), cedict)
    write_onsets(readings)


if __name__ == '__main__':
    main()
