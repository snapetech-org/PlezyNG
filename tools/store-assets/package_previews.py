#!/usr/bin/env python3
"""Label rendered Flutter previews and package them separately from store captures."""
import argparse
import hashlib
import json
from pathlib import Path
import zipfile
from PIL import Image, ImageDraw, ImageFont, ImageOps

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--input', required=True, type=Path)
parser.add_argument('--output', required=True, type=Path)
parser.add_argument('--source-sha', required=True)
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
try:
    font = ImageFont.truetype('DejaVuSans.ttf', 19)
    heading = ImageFont.truetype('DejaVuSans.ttf', 30)
except OSError:
    font = ImageFont.load_default(size=19)
    heading = ImageFont.load_default(size=30)
records = []
for source in sorted(args.input.glob('*-preview.png')):
    image = Image.open(source).convert('RGB')
    labeled = Image.new('RGB', (image.width, image.height + 48), '#0a1118')
    labeled.paste(image, (0, 0))
    draw = ImageDraw.Draw(labeled)
    draw.text((16, image.height + 14), 'INTERFACE PREVIEW · Flutter widgets / sample data · not a device capture', font=font, fill='#78d8cc')
    output = args.output / source.name
    labeled.save(output)
    records.append({'name': output.name, 'render_dimensions': list(image.size), 'dimensions': list(labeled.size),
                    'sha256': hashlib.sha256(output.read_bytes()).hexdigest(), 'kind': 'labeled-widget-preview'})
manifest = {'schema_version': 1, 'source_sha': args.source_sha, 'store_upload_eligible': False,
            'method': 'Production Flutter widgets rendered by flutter_test with appearance fixtures; demo metadata; no device execution',
            'images': records}
(args.output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
(args.output / 'README.txt').write_text('Pleazyng interface previews\n\nThese are production Flutter widgets with synthetic fixture data, not screenshots from a running packaged app.\nDo not upload them to store screenshot slots or describe them as Fire TV hardware captures.\nPlayer previews use simulated state and do not run a native decoder.\n\nSource: ' + args.source_sha + '\n\n' + '\n'.join(record['name'] for record in records) + '\n')
columns = 3
rows = (len(records) + columns - 1) // columns
sheet = Image.new('RGB', (1920, 125 + rows * 455), '#101820')
draw = ImageDraw.Draw(sheet)
draw.text((36, 25), 'Pleazyng · Interface previews', font=heading, fill='white')
draw.text((36, 74), 'Flutter widgets with sample data · not device screenshots · not for store submission', font=font, fill='#78d8cc')
for index, record in enumerate(records):
    row, col = divmod(index, columns)
    x, y = 20 + col * 640, 125 + row * 455
    with Image.open(args.output / record['name']) as source:
        thumb = ImageOps.contain(source.convert('RGB'), (600, 385))
    sheet.paste(thumb, (x + (600 - thumb.width) // 2, y))
    label = record['name'].removesuffix('-preview.png').replace('-', ' ').title()
    draw.text((x + 8, y + 405), label, font=font, fill='#b8c9d7')
sheet.save(args.output / 'contact-sheet.jpg', quality=92)
with zipfile.ZipFile(args.output / 'pleazyng-interface-previews.zip', 'w', zipfile.ZIP_DEFLATED) as archive:
    for path in sorted(args.output.iterdir()):
        if path.is_file() and path.suffix != '.zip':
            archive.write(path, path.name)
print(args.output)
