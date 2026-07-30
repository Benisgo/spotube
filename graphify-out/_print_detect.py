import json
from pathlib import Path

d = json.loads(Path('graphify-out/.graphify_detect.json').read_text(encoding='utf-8'))
cats = d['files']
code = len(cats.get('code', []))
doc = len(cats.get('document', []))
paper = len(cats.get('paper', []))
img = len(cats.get('image', []))
video = len(cats.get('video', []))
total = d.get('total_files', code+doc+paper+img+video)
words = d.get('total_words', 0)
print(f"Corpus: {total} files - ~{words} words")
print(f"  code:   {code} files")
print(f"  docs:   {doc} files")
print(f"  papers: {paper} files")
print(f"  images: {img} files")
print(f"  video:  {video} files")
print(f"scan_root: {d.get('scan_root','')}")
sens = d.get('skipped_sensitive', [])
if sens:
    print(f"skipped_sensitive ({len(sens)}): {sens}")
