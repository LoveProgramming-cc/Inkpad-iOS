#!/usr/bin/env python3
"""The desktop half of the cross-implementation sync test.

Runs the desktop app's own model.py and gdrive.sync() - with only cairo, Pango and
poppler stubbed out, since none of them exist on a Mac - against the folder "Drive"
that InkpadTests/CompatTests.swift uses.

    tools/compat.py <path to the desktop app's folder> <test folder>
"""
import hashlib
import json
import os
import sys
import types
import uuid
from unittest import mock

app_dir, base = sys.argv[1], sys.argv[2]
sys.path.insert(0, app_dir)
os.environ['INKPAD_HOME'] = os.path.join(base, 'desktop-home')

sys.modules['cairo'] = mock.MagicMock()
gi = types.ModuleType('gi')
repo = types.ModuleType('gi.repository')
repo.GLib = mock.MagicMock()
gi.repository = repo
sys.modules['gi'], sys.modules['gi.repository'] = gi, repo

import inkpad  # noqa: E402

ptext = types.ModuleType('inkpad.ptext')
ptext.measure = lambda cr, text, size, wrap=0.0: (min(wrap or 1e9, len(text) * size * 0.6), size * 1.3)
ptext.show = lambda *a, **k: None
sys.modules['inkpad.ptext'] = ptext
inkpad.ptext = ptext
pdf = types.ModuleType('inkpad.pdf')


class PdfDoc:
    def __init__(self, data):
        self.data, self.n_pages = bytes(data), 1

    def page_size(self, index):
        return 595.0, 842.0


pdf.PdfDoc = PdfDoc
sys.modules['inkpad.pdf'] = pdf
inkpad.pdf = pdf

from inkpad import gdrive, model  # noqa: E402


class DirDrive:
    """Same layout as the Swift DirDrive: <id>.bin files and a names.json."""
    on_bytes = None

    def __init__(self, path):
        self.dir = path
        os.makedirs(path, exist_ok=True)

    def _names(self):
        try:
            with open(os.path.join(self.dir, 'names.json'), encoding='utf-8') as f:
                return json.load(f)
        except OSError:
            return {}

    def _name(self, file_id, name):
        names = self._names()
        names[file_id] = name
        with open(os.path.join(self.dir, 'names.json'), 'w', encoding='utf-8') as f:
            json.dump(names, f, ensure_ascii=False)

    def _file(self, file_id):
        return os.path.join(self.dir, file_id + '.bin')

    def root(self):
        return 'root'

    def alive(self, file_id):
        return file_id == 'root' or os.path.exists(self._file(file_id))

    def children(self, folder):
        return [{'id': k, 'name': v} for k, v in self._names().items()]

    def find(self, name, parent):
        return next((k for k, v in self._names().items() if v == name), None)

    def get_json(self, file_id):
        with open(self._file(file_id), encoding='utf-8') as f:
            return json.load(f)

    def put_json(self, name, value, parent, file_id=None):
        new = file_id or 'p' + uuid.uuid4().hex[:8]
        with open(self._file(new), 'w', encoding='utf-8') as f:
            json.dump(value, f, ensure_ascii=False)
        if not file_id:
            self._name(new, name)
        return new

    def rename(self, file_id, name):
        self._name(file_id, name)

    def upload(self, path, name, parent, file_id=None):
        new = file_id or 'p' + uuid.uuid4().hex[:8]
        with open(path, 'rb') as src, open(self._file(new), 'wb') as dst:
            data = src.read()
            dst.write(data)
        if not file_id:
            self._name(new, name)
        return new, hashlib.md5(data).hexdigest()

    def download(self, file_id, dest):
        with open(self._file(file_id), 'rb') as src, open(dest, 'wb') as dst:
            dst.write(src.read())


root = os.path.join(base, 'desktop')
os.makedirs(root, exist_ok=True)
drive = DirDrive(os.path.join(base, 'cloud'))

summary = gdrive.sync(root, drive)
assert summary['down'] == 3, summary
files, folders = gdrive._scan(root)
assert sorted(files) == ['将被删除.inkpad', '白板.inkpad', '课程/笔记.inkpad'], files

# What the iOS app wrote, read by the desktop's loader.
notes = files['课程/笔记.inkpad']
doc = model.Document.load(notes)
with open(os.path.join(base, 'ios-items.txt'), encoding='utf-8') as f:
    expected = f.read().split()
page = doc.pages[0]
assert [it.id for it in page.items] == expected, 'item ids'
assert [it.kind for it in page.items] == ['s', 's', 'h', 't', 't', 'i'], [it.kind for it in page.items]
assert (page.paper, len(doc.pages), doc.pages[1].bookmark, doc.pages[1].outline) == ('grid', 2, True, '第二页')
stroke, tape, arrow, text, note, image = page.items
assert stroke.tool == 'fountain' and abs(stroke.sens - 1.2) < 1e-9 and len(stroke.pts) == 3
assert abs(stroke.pts[1][0] - 60) < 0.01 and abs(stroke.pts[1][2] - 0.8) < 0.01, stroke.pts
assert tape.tool == 'tape' and tape.open and arrow.shape == 'arrow' and arrow.width == 2
assert text.text == '你好 Inkpad' and note.bg == (1, 0.93, 0.55) and note.wrap == 170
assert image.data[:8] == b'\x89PNG\r\n\x1a\n' and (image.w, image.h) == (80, 60)
assert doc.pages[1].items[0].dash == 1 and doc.pages[1].items[0].tool == 'hl'
assert doc.cover_spec == ('label', tuple(model.COVER_COLORS[3])), doc.cover_spec
board = model.Document.load(files['白板.inkpad'])
assert board.pages[0].board and board.pages[0].paper == 'dots'

# Edit it the way the desktop app does: through the document's undo actions.
new = model.Stroke('brush', (0.2, 0.4, 0.6), 2.4, [(100.0, 600.0, 0.3), (150.5, 620.25, 0.9), (200.0, 610.0, 0.5)], 1.5)
doc.add_items(page, [new])
doc.remove_items(page, [arrow])
doc.do(('pages', [], [(2, model.Page(595.0, 842.0, 'grid'))]))
doc.save()
with open(os.path.join(base, 'desktop-item.txt'), 'w') as f:
    f.write(model.item_id(new))

# A notebook made on the desktop, a rename and a deletion.
made = model.Document({'w': 595.0, 'h': 842.0, 'paper': 'cornell', 'color': (1.0, 1.0, 1.0)})
made.add_items(made.pages[0], [model.Text(50.0, 60.0, '来自桌面', 18.0, (0.0, 0.0, 0.0), 300.0),
                               model.Shape('ellipse', 100.0, 200.0, 300.0, 320.0, (0.9, 0.1, 0.1), 1.5)])
made.save(os.path.join(root, '桌面新建.inkpad'))
os.rename(files['白板.inkpad'], os.path.join(root, '画板.inkpad'))
os.remove(files['将被删除.inkpad'])
meta_path = os.path.join(root, '.library.json')
meta = json.load(open(meta_path, encoding='utf-8'))
assert meta['favorites'] == ['课程/笔记.inkpad'], meta
meta['favorites'].append('桌面新建.inkpad')
meta['ts'] = meta['ts'] + 100
json.dump(meta, open(meta_path, 'w', encoding='utf-8'), ensure_ascii=False)

summary = gdrive.sync(root, drive)
assert (summary['up'], summary['moved'], summary['removed']) == (2, 1, 1), summary
open(os.path.join(base, 'desktop-done'), 'w').close()
print('desktop side ok:', summary)
