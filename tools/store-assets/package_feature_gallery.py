#!/usr/bin/env python3
"""Export reviewed feature renders with reproducible source provenance."""
import argparse
import hashlib
import json
import subprocess
from pathlib import Path
from PIL import Image

SCENES = {
 'ebook-reader': ('EPUB reading', 'lib/screens/sources/publication_reader_screen.dart'),
 'ebook-reader-phone': ('Phone EPUB reading', 'lib/screens/sources/publication_reader_screen.dart'),
 'ebook-reading-settings': ('Reading settings', 'lib/screens/sources/publication_reader_screen.dart'),
 'book-library-detail': ('Book editions', 'lib/screens/sources/source_detail_screen.dart'),
 'audiobook-player': ('Audiobook chapters and controls', 'lib/screens/sources/source_player_screen.dart'),
 'podcast-player': ('Podcast chapters and controls', 'lib/screens/sources/source_player_screen.dart'),
 'music-player': ('Music and queue', 'lib/screens/music/now_playing_screen.dart'),
 'steam-library': ('Steam library', 'lib/screens/games/game_library_view.dart'),
 'steam-controller-layout': ('Controller layout', 'lib/screens/games/steam_input_dialog.dart'),
 'steam-touch-layout': ('Touch controller layout', 'lib/screens/games/steam_touch_layout_dialog.dart'),
 'connected-sources': ('Files and cloud sources', 'lib/screens/sources/sources_screen.dart'),
 'open-media': ('Open media', 'lib/screens/sources/open_media_screen.dart'),
 'find-your-next': ('Find your next', 'lib/screens/discovery/discovery_deck_view.dart'),
 'subtitle-ai': ('AI subtitles', 'lib/widgets/video_controls/sheets/subtitle_ai_sheet.dart'),
 'multiview': ('Multiview workspace', 'lib/multiview/workspace_overlay.dart'),
 'live-tv-guide': ('Live TV guide', 'lib/screens/livetv/tabs/guide_tab.dart'),
 'visualizer-library': ('Visualizer library', 'lib/widgets/music/visualizer_preset_browser.dart'),
}
def digest(path):
 return hashlib.sha256(path.read_bytes()).hexdigest()
def main():
 parser=argparse.ArgumentParser(description=__doc__)
 parser.add_argument('input',type=Path)
 parser.add_argument('output',type=Path)
 args=parser.parse_args()
 root=Path(__file__).resolve().parents[2]
 args.output.mkdir(parents=True,exist_ok=True)
 revision=subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip()
 entries=[]
 for name,(title,component) in SCENES.items():
  src=args.input/f'{name}-dark.png'
  with Image.open(src) as im:
   im.load()
   if min(im.size)<500: raise ValueError(f'Undersized image: {src}')
   if im.mode=='RGBA' and im.getextrema()[3]!=(255,255): raise ValueError(f'Transparency: {src}')
   rgb=im.convert('RGB')
   if max(rgb.convert('L').getextrema())-min(rgb.convert('L').getextrema())<80: raise ValueError(f'Empty image: {src}')
   target=args.output/src.name
   rgb.save(target,optimize=True)
   size=list(rgb.size)
  component_path=root/component
  if not component_path.is_file(): raise ValueError(f'Missing component: {component}')
  entries.append(dict(file=target.name,title=title,dimensions=size,sha256=digest(target),component=component,component_sha256=digest(component_path),renderer='Production PublicationServer / Foliate browser engine' if name.startswith('ebook-') else 'Production Flutter widgets',state='Local populated gallery fixture; no live account or native playback qualification'))
 sources={str(p.relative_to(root)):digest(p) for p in sorted((root/'tools/store-assets').glob('feature*')) if p.is_file()}
 (args.output/'manifest.json').write_text(json.dumps(dict(source_revision=revision,producer_sources=sources,images=entries),indent=2)+'\n')
 (args.output/'README.md').write_text('''# Feature gallery\n\nSeventeen dark-mode views rendered from production components. Select images in the main README for full resolution. `manifest.json` records source revision, component hashes, renderer and fixture state.\n\nRegenerate with `tools/store-assets/feature_reader_capture_test.dart` followed by `feature_capture_test.dart`; both require `PLEAZYNG_FEATURE_OUTPUT`. See the store asset tooling README for commands.\n\n## Image credits\n\nThe Night Library, Blue Hour Sessions, and Signal & Story are original gallery fixtures; their covers are original project artwork. Steam library cover art belongs to the respective game publishers: [Portal 2](https://store.steampowered.com/app/620/), [Stardew Valley](https://store.steampowered.com/app/413150/), and [Hades](https://store.steampowered.com/app/1145360/), sourced through the production Steam CDN artwork paths. Multiview uses the attributed [Caminandes frame](../../../tools/store-assets/fixtures/README.md).\n''')
 print(f'Exported {len(entries)} validated images to {args.output}')
if __name__=='__main__': main()
