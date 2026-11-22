#!/usr/bin/env python3
"""Render the original YinTrace mark into native icon and Apple launch assets.
Development dependencies: CairoSVG and Pillow.
"""
import io
import json
from pathlib import Path

import cairosvg
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
svg = (ROOT / 'assets/branding/icon.svg').read_bytes()
for platform in ('ios', 'macos'):
    folder = ROOT / platform / 'Runner/Assets.xcassets/AppIcon.appiconset'
    contents = json.loads((folder / 'Contents.json').read_text())
    for entry in contents['images']:
        size = round(float(entry['size'].split('x')[0]) * float(entry['scale'][:-1]))
        cairosvg.svg2png(bytestring=svg, write_to=str(folder / entry['filename']),
                        output_width=size, output_height=size)

android_resources = ROOT / 'android/app/src/main/res'
for density, size in [('mdpi', 48), ('hdpi', 72), ('xhdpi', 96), ('xxhdpi', 144), ('xxxhdpi', 192)]:
    target = android_resources / f'mipmap-{density}/ic_launcher.png'
    cairosvg.svg2png(bytestring=svg, write_to=str(target), output_width=size, output_height=size)

icon = cairosvg.svg2png(bytestring=svg, output_width=256, output_height=256)
windows_icon = ROOT / 'windows/runner/resources/app_icon.ico'
with Image.open(io.BytesIO(icon)) as image:
    image.save(windows_icon, sizes=[(size, size) for size in (16, 20, 24, 32, 40, 48, 64, 128, 256)])

# Launch art has transparent surroundings so the system paper color can adapt.
mark = svg.decode().replace('<rect width="1024" height="1024" fill="#FAFAF8"/>', '')
folder = ROOT / 'ios/Runner/Assets.xcassets/LaunchImage.imageset'
entries = []
for scale in (1, 2, 3):
    name = f'LaunchImage{("@" + str(scale) + "x") if scale > 1 else ""}.png'
    cairosvg.svg2png(bytestring=mark.encode(), write_to=str(folder / name),
                    output_width=144 * scale, output_height=144 * scale)
    entries.append(dict(idiom='universal', filename=name, scale=f'{scale}x'))
    dark_name = name.replace('.png', '-dark.png')
    dark = mark.replace('#1E2230', '#EDEEF2').replace('#179C78', '#2FC197')
    cairosvg.svg2png(bytestring=dark.encode(), write_to=str(folder / dark_name),
                    output_width=144 * scale, output_height=144 * scale)
    entries.append(dict(idiom='universal', filename=dark_name, scale=f'{scale}x',
                        appearances=[dict(appearance='luminosity', value='dark')]))
(folder / 'Contents.json').write_text(json.dumps(dict(images=entries, info=dict(version=1, author='xcode')), indent=2)+'\n')
