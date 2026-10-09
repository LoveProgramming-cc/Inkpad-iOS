#!/usr/bin/env python3
"""The desktop half of the Goodnotes cross-implementation test.

Runs the desktop app's own goodnotes.py (with cairo, Pango and poppler stubbed out, as in
compat.py) so that InkpadTests/GoodnotesTests.swift can be held against it:

    tools/goodnotes_compat.py <desktop app folder> <test folder> make
        writes synthetic.goodnotes, a file put together by hand so that every kind of
        element and every stroke layout the reader knows occurs in it, with what the desktop
        reader makes of it (synthetic.json); and desktop.goodnotes, written by the desktop's
        own exporter, with what it reads back (desktop.json)
    (the Swift test then reads both, compares, and writes ios.goodnotes and ios.json)
    tools/goodnotes_compat.py <desktop app folder> <test folder> check
        reads ios.goodnotes with the desktop reader and compares it with ios.json
"""
import json
import os
import struct
import sys
import types
import zipfile
from unittest import mock

app_dir, base, stage = sys.argv[1], sys.argv[2], sys.argv[3]
sys.path.insert(0, app_dir)
os.makedirs(base, exist_ok=True)
os.environ['INKPAD_HOME'] = os.path.join(base, 'desktop-home')

sys.modules['cairo'] = mock.MagicMock()
gi = types.ModuleType('gi')
repo = types.ModuleType('gi.repository')
repo.GLib = mock.MagicMock()
gi.repository = repo
gi.require_version = lambda *a: None
sys.modules['gi'], sys.modules['gi.repository'] = gi, repo

import inkpad  # noqa: E402

ptext = types.ModuleType('inkpad.ptext')
ptext.measure = lambda cr, text, size, wrap=0.0: (min(wrap or 1e9, len(text) * size * 0.6), size * 1.3)
ptext.show = lambda *a, **k: None
sys.modules['inkpad.ptext'] = ptext
inkpad.ptext = ptext
pdf = types.ModuleType('inkpad.pdf')


class PdfDoc:
    """A stand-in for poppler: the page sizes, from the page objects' media boxes."""

    def __init__(self, data):
        import re
        self.data = bytes(data)
        boxes = {}
        find = lambda body: re.search(rb'/MediaBox\s*\[\s*0\s+0\s+([0-9.]+)\s+([0-9.]+)\s*\]', body)
        size = lambda box: (float(box.group(1)), float(box.group(2)))
        shared = None   # a page without a box of its own has its parent's
        for number, body in re.findall(rb'(\d+) 0 obj(.*?)endobj', self.data, re.S):
            if re.search(rb'/Type\s*/Pages\b', body):
                shared = find(body) and size(find(body))
            elif re.search(rb'/Type\s*/Page\b', body):
                boxes[int(number)] = find(body) and size(find(body))
        kids = re.search(rb'/Kids\s*\[(.*?)\]', self.data, re.S)
        order = [int(n) for n in re.findall(rb'(\d+) 0 R', kids.group(1))] if kids else sorted(boxes)
        self.sizes = [boxes[n] or shared for n in order if n in boxes]
        self.n_pages = len(self.sizes)
        if not self.sizes:
            raise ValueError('no pages')

    def page_size(self, index):
        return self.sizes[index]


pdf.PdfDoc = PdfDoc
sys.modules['inkpad.pdf'] = pdf
inkpad.pdf = pdf

from inkpad import goodnotes as gn, model  # noqa: E402

f, rec = gn._f, gn._record


def dump(doc, title, stats):
    pages = []
    for page in doc.pages:
        items = []
        for it in page.items:
            if it.kind == 's':
                items.append({'k': 's', 'tool': it.tool, 'color': list(it.color), 'width': it.width, 'sens': it.sens,
                              'dash': it.dash, 'pts': [list(p) for p in it.pts]})
            elif it.kind == 't':
                items.append({'k': 't', 'x': it.x, 'y': it.y, 'text': it.text, 'size': it.size, 'color': list(it.color),
                              'wrap': it.wrap, 'bg': list(it.bg) if it.bg else None})
            elif it.kind == 'h':
                items.append({'k': 'h', 'shape': it.shape, 'box': [it.x0, it.y0, it.x1, it.y1], 'color': list(it.color),
                              'width': it.width})
            else:
                items.append({'k': it.kind})
        pages.append({'w': page.w, 'h': page.h, 'board': page.board, 'pdf': page.pdf is not None, 'items': items})
    return {'title': title, 'stats': {k: stats.get(k, 0) for k in ('strokes', 'texts', 'shapes', 'formulas', 'images', 'skipped')},
            'pages': pages}


def close(a, b, where=''):
    if isinstance(a, dict):
        assert isinstance(b, dict) and a.keys() == b.keys(), (where, a, b)
        for k in a:
            close(a[k], b[k], where + '/' + str(k))
    elif isinstance(a, list):
        assert isinstance(b, list) and len(a) == len(b), (where, len(a), len(b) if isinstance(b, list) else b)
        for n, (x, y) in enumerate(zip(a, b)):
            close(x, y, '%s[%d]' % (where, n))
    elif isinstance(a, float) or isinstance(b, float):
        assert abs(a - b) <= 1e-6 * max(1.0, abs(a)), (where, a, b)
    else:
        assert a == b, (where, a, b)


# -- putting a file together by hand ------------------------------------------

def vec(*values):
    """Float fields 1..n; a zero is left out, as Goodnotes leaves it out."""
    return b''.join(f(n + 1, float(v)) for n, v in enumerate(values) if v != 0)


def stored(raw):
    return b'bv4-' + struct.pack('<I', len(raw)) + raw + b'bv4$'


def lz4(raw):
    """A small LZ4 block compressor, enough to give the reader matches to follow."""
    out = bytearray()
    i, anchor, n = 0, 0, len(raw)

    def emit(literals, match_len, offset):
        lit = len(literals)
        token = (min(lit, 15) << 4) | (min(match_len - 4, 15) if match_len else 0)
        out.append(token)
        if lit >= 15:
            rest = lit - 15
            while rest >= 255:
                out.append(255)
                rest -= 255
            out.append(rest)
        out.extend(literals)
        if match_len:
            out.extend(struct.pack('<H', offset))
            if match_len - 4 >= 15:
                rest = match_len - 4 - 15
                while rest >= 255:
                    out.append(255)
                    rest -= 255
                out.append(rest)

    while i + 4 <= n:
        best, best_at = 0, 0
        for j in range(max(0, i - 300), i):
            k = 0
            while i + k < n and raw[j + k] == raw[i + k]:   # may run past i: an overlapping match
                k += 1
            if k > best:
                best, best_at = k, j
        if best >= 4:
            emit(raw[anchor:i], best, i - best_at)
            i += best
            anchor = i
        else:
            i += 1
    emit(raw[anchor:], 0, 0)
    return b'bv41' + struct.pack('<II', n, len(out)) + bytes(out) + b'bv4$'


def tpl(sig, payload):
    sig = sig.encode() + b'\0'
    return b'tpl\0' + struct.pack('<I', 8 + len(sig) + len(payload)) + sig + payload


def arr_h(values):
    return struct.pack('<I', len(values)) + struct.pack('<%dH' % len(values), *values)


def arr_f(values):
    return struct.pack('<I', len(values)) + struct.pack('<%df' % len(values), *values)


def arr_s(rows):
    return struct.pack('<I', len(rows)) + b''.join(struct.pack('<%df' % len(r), *r) for r in rows)


COUNTER = [10]


def element(kind, body, eid=None, made=None, stamp_field=7):
    COUNTER[0] += 1
    eid = eid or 'E%04d' % COUNTER[0]
    stamp = f(stamp_field, f(1, f(1, made if made is not None else COUNTER[0])))
    header = rec(f(1, eid) + f(2, b'hdr') + f(9, COUNTER[0]))
    return header + rec(f(kind, f(1, eid) + body + stamp))


def color(r, g, b, a=1.0):
    return f(1, float(r)) + f(2, float(g)) + f(3, float(b)) + f(4, float(a))


def make_synthetic(path):
    notes = bytearray()
    # 1 constant width, LZ4 compressed, with an offset it was moved by
    constant = tpl('vuA(v)A(S(uu))A(S(uuuu))', struct.pack('<Hf', 2, 3.5) + arr_h([0, 1, 1, 0, 1])
                   + arr_s([(10, 20), (200, 210)]) + arr_s([(15, 25, 20, 30), (25, 35, 30, 40), (205, 215, 210, 220)]))
    notes += element(7, f(2, lz4(constant)) + f(4, color(0.1, 0.2, 0.3)) + f(6, vec(5, -7)))
    # 2 variable width
    variable = tpl('vA(v)A(u)A(u)', struct.pack('<H', 3) + arr_h([4, 5, 5])
                   + arr_f([50, 60, 1.0, 0]) + arr_f([55, 65, 1.5, 60, 70, 2.0, 0, 0, 0, 65, 75, 1.2, 70, 80, 0.8, 0, 0, 0]))
    notes += element(7, f(2, stored(variable)) + f(4, color(0.9, 0.1, 0.1)))
    # 3 a brush: a taper of dabs, then the broad nib, with the nib's edge given
    brush = tpl('vuA(v)A(u)A(u)uuuuuA(u)', struct.pack('<Hf', 4, 0.0) + arr_h([2, 2, 3, 6, 7, 7])
                + arr_f([100, 100, 1.0, 102, 101, 1.6, 104, 102, 3.0, 0])
                + arr_f([0, 0, 103, 101.5, 0, 2.0, 106, 103, 108, 104, 3.2, 3.4, 0, 0, 0, 112, 104, 116, 108, 3.1, 2.9, 0, 0, 0])
                + struct.pack('<5f', 0, 0, 0, 0, 0) + arr_f([0, 0, 0, 4.0, 1.2, 0.9, 0]))
    notes += element(7, f(2, lz4(brush)) + f(4, color(0.0, 0.0, 0.0)))
    # 3 again: only a taper (the tail is used), and one at a constant width
    taper = tpl('vuA(v)A(u)A(u)', struct.pack('<Hf', 4, 0.0) + arr_h([2, 3]) + arr_f([300, 300, 2.0]) + arr_f([0, 0, 305, 303, 0, 1.0]))
    notes += element(7, f(2, stored(taper)) + f(4, color(0.2, 0.2, 0.2)))
    steady = tpl('vuA(v)A(u)A(u)', struct.pack('<Hf', 4, 2.84) + arr_h([2, 0, 1]) + arr_f([400, 400, 1.0, 402, 401]) + arr_f([404, 402, 408, 406]))
    notes += element(7, f(2, stored(steady)) + f(4, color(0.3, 0.3, 0.3)))
    # 4 a base width with a factor at every point (one factor is not one, and counts as 1)
    factors = tpl('vuA(v)A(S(uuuuu))A(S(uuuuuuuuuuu))', struct.pack('<Hf', 5, 2.0) + arr_h([0, 1, 1])
                  + arr_s([(500, 500, 0.5, 0, 0)])
                  + arr_s([(0, 505, 505, 1.5, 0, 0, 510, 510, 2.0, 0, 0), (0, 515, 512, 99.0, 0, 0, 520, 514, 0.8, 0, 0)]))
    notes += element(7, f(2, lz4(factors)) + f(4, color(0.0, 0.4, 0.8)))
    # a highlighter by its flag, and one by its alpha
    notes += element(7, f(2, stored(constant)) + f(4, color(1.0, 0.9, 0.2)) + f(5, 1))
    notes += element(7, f(2, stored(constant)) + f(4, color(0.2, 0.9, 1.0, 0.5)))
    # recognised shapes: stored as geometry, the drawn path empty
    empty = stored(tpl('vuA(v)A(S(uu))A(S(uuuu))', struct.pack('<Hf', 2, 1.0) + arr_h([]) + arr_s([]) + arr_s([])))
    w15 = f(15, 2.5)
    poly = f(1, f(1, vec(600, 600)) + f(1, vec(650, 600)) + f(1, vec(650, 640))) + w15
    curve = f(2, f(1, vec(600, 700)) + f(2, vec(640, 660)) + f(3, vec(680, 700))) + w15 + f(5, f(1, 1))
    box = f(3, f(1, vec(700, 300)) + f(2, vec(80, 40)))
    oval = f(4, f(1, vec(300, 700)) + f(2, vec(60, 30)) + f(3, 0.5)) + w15
    for shape in (poly, curve, box, oval):
        notes += element(7, f(2, empty) + f(4, color(0.5, 0.1, 0.6)) + f(9, shape))
    # an element that was replaced by a later record, and one that was erased
    notes += element(7, f(2, stored(constant)) + f(4, color(1, 0, 0)), eid='TWICE', made=3)
    notes += element(7, f(2, stored(variable)) + f(4, color(0, 1, 0)), eid='TWICE', made=3)
    notes += element(7, f(2, stored(constant)) + f(4, color(0, 0, 1)) + f(14, 1))
    # text: a box, a sticky note, an old RTF box
    runs = lz4(f(1, f(1, 'Hello ')) + f(1, f(1, '世界\nsecond line\n')))
    notes += element(21, f(20, f(1, vec(40, 50))) + f(21, f(2, vec(300))) + f(32, f(1, f(2, runs)) + f(2, vec(250))
                                                                          + f(5, f(1, f(40, 24.0)))))
    notes += element(21, f(20, f(1, vec(40, 150))) + f(21, b'') + f(32, f(1, f(2, stored(f(1, f(1, 'plain'))))) + f(2, vec(180))))
    notes += element(21, f(20, f(1, vec(40, 150))) + f(32, f(1, f(2, stored(f(1, f(1, '  \n')))))))   # nothing in it
    notes += element(20, f(20, f(1, vec(400, 50))) + f(21, f(2, vec(420))) + f(30, vec(1.0, 0.9, 0.4))
                     + f(31, f(1, f(2, stored(f(1, f(1, 'a note')))))))
    rtf = ('{\\rtf1\\ansi{\\fonttbl{\\f0 Helvetica;}}{\\colortbl;\\red0\\green0\\blue0;}\\f0\\fs24 caf\\\'e9 \\u20320?\\u22909? '
           'tab\\tab here\\par line two \\{braces\\} \\u-10179?\\u-8704? end}')
    notes += element(8, f(3, f(1, vec(100, 900)) + f(2, vec(240, 60))) + f(6, rtf))
    # a connector, a formula (one part inside its frame, one outside), and things that are skipped
    notes += element(22, f(20, f(2, vec(10, 1000)) + f(3, f(1, vec(210, 1100)))) + f(32, f(1, 3.0) + f(3, f(1, vec(0.2, 0.4, 0.6)))))
    inside = tpl('vuA(v)A(S(uu))A(S(uuuu))', struct.pack('<Hf', 2, 1.5) + arr_h([0, 1]) + arr_s([(810, 810)]) + arr_s([(820, 815, 830, 820)]))
    notes += element(11, f(2, f(1, vec(800, 800)) + f(2, vec(100, 60))) + f(11, f(1, stored(inside)) + f(2, color(0.1, 0.1, 0.1)))
                     + f(11, f(1, stored(constant)) + f(2, color(0.1, 0.1, 0.1))))
    notes += element(11, f(2, f(1, vec(800, 800)) + f(2, vec(100, 60))) + f(6, 1) + f(11, f(1, stored(inside)) + f(2, color(0, 0, 0))))
    notes += element(1, f(2, f(1, vec(5, 5)) + f(2, vec(0.5, 0.5))) + f(4, 'ATT'), stamp_field=5)        # a speck
    notes += element(1, f(2, f(1, vec(5, 5)) + f(2, vec(50, 50))) + f(4, 'MISSING'), stamp_field=5)   # no such attachment
    notes += element(9, f(2, b''))
    notes += element(99, f(2, b'whatever'))
    notes += element(7, f(2, stored(tpl('zz', b''))) + f(4, color(0, 0, 0)))   # a layout nobody knows

    doc_id = 'DOC'
    events = rec(f(1, doc_id) + f(30, f(1, doc_id) + f(2, f(1, '合成文档') + f(2, b''))))
    events += rec(f(1, 'T1') + f(2, f(2, 'T1') + f(4, '') + f(5, 1) + f(8, vec(1100, 1540))))
    events += rec(f(1, 'T2') + f(2, f(2, 'T2') + f(4, 'NOPDF') + f(5, 1) + f(8, vec(770, 1100))))
    for n, (pid, template, key) in enumerate((('PAGE00A0', 'T1', 'P2'), ('PAGE00B0', '', 'P1'), ('PAGE00C0', 'T2', 'P9'))):
        events += rec(f(1, pid) + f(54, f(2, pid) + f(3, f(1, template)) + f(4, f(1, key))))
    events += rec(f(1, 'PAGE00C0') + f(55, f(2, 'PAGE00C0') + f(3, f(1, 'P0'))))   # moved to the front
    index = rec(f(1, 'PAGE00A1') + f(2, 'notes/PAGE00A1')) + rec(f(1, 'PAGE00C0') + f(2, 'notes/c'))
    second = element(7, f(2, stored(variable)) + f(4, color(0.4, 0.4, 0.4)))
    with zipfile.ZipFile(path, 'w', zipfile.ZIP_DEFLATED) as z:
        z.writestr('index.events.pb', events)
        z.writestr('index.notes.pb', index)
        z.writestr('index.attachments.pb', rec(f(1, 'NOPDF') + f(2, 'attachments/nopdf')))
        z.writestr('attachments/nopdf', b'not a pdf')
        z.writestr('notes/PAGE00A1', bytes(notes))
        z.writestr('notes/c', second)


def make_desktop(path):
    doc = model.Document({'w': 595.0, 'h': 842.0, 'paper': 'grid', 'color': (1.0, 1.0, 1.0)})
    page = doc.pages[0]
    doc.add_items(page, [
        model.Stroke('ball', (0.1, 0.2, 0.3), 1.6, [(50.0, 60.0, 0.5), (80.0, 90.5, 0.5), (120.25, 70.0, 0.5)]),
        model.Stroke('fountain', (0.8, 0.1, 0.1), 2.0, [(200.0, 200.0, 0.2), (220.0, 240.0, 0.9), (260.0, 250.0, 0.5)], 1.2),
        model.Stroke('hl', (1.0, 0.9, 0.2), 14.0, [(100.0, 400.0, 0.5), (300.0, 400.0, 0.5)]),
        model.Stroke('ball', (0.0, 0.0, 0.0), 1.2, [(10.0, 10.0, 0.5)]),
        model.Text(50.0, 500.0, 'not a stroke', 18.0, (0.0, 0.0, 0.0), 300.0),
    ])
    doc.do(('pages', [], [(1, model.Page(420.0, 595.0, 'dots'))]))
    doc.add_items(doc.pages[1], [model.Stroke('brush', (0.2, 0.6, 0.2), 2.4, [(30.0, 30.0, 0.3), (60.0, 80.0, 0.8)], 1.5)])
    with mock.patch.object(model, 'render_page', lambda *a, **k: None), mock.patch.object(gn, '_thumbnail', lambda doc: b'jpeg'):
        gn.save(doc, path, '桌面导出')


if stage == 'make':
    for name, make in (('synthetic', make_synthetic), ('desktop', make_desktop)):
        path = os.path.join(base, name + '.goodnotes')
        make(path)
        result = dump(*gn.load(path))
        with open(os.path.join(base, name + '.json'), 'w', encoding='utf-8') as out:
            json.dump(result, out, ensure_ascii=False)
        print(name, 'read by the desktop code:', result['stats'], [len(p['items']) for p in result['pages']])
else:
    with open(os.path.join(base, 'ios.json'), encoding='utf-8') as src:
        expected = json.load(src)
    close(expected, dump(*gn.load(os.path.join(base, 'ios.goodnotes'))))
    print('the desktop code reads what the iPad app exported:', expected['stats'])
