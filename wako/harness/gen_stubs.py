#!/usr/bin/env python3
"""Generate permissive GDScript stubs for preloaded RaulsMod modules missing from the package.

For every res:// preload that does not exist under ../game, collect how the
aliasing const is used (Alias.member( -> static func, Alias.UPPER -> const) and
emit a stub. Hand-written stubs in stubs/ take precedence (never overwritten).
"""
import os, re, sys
HERE = os.path.dirname(os.path.abspath(__file__))
GAME = os.path.join(HERE, '..', 'game')
STUBS = os.path.join(HERE, 'stubs')
AUTO = os.path.join(HERE, 'stubs_auto')
srcs = {}
for d, _, fs in os.walk(GAME):
    if '/.claude' in d: continue
    for f in fs:
        if f.endswith('.gd'):
            p = os.path.join(d, f); srcs[p] = open(p, encoding='utf-8', errors='ignore').read()
missing = {}
for p, s in srcs.items():
    for alias, path in re.findall(r'const\s+(\w+)\s*:?=\s*preload\("res://([^"]+\.gd)"\)', s):
        if not os.path.exists(os.path.join(GAME, path)):
            missing.setdefault(path, set()).add(alias)
    for path in re.findall(r'(?<!pre)load\("res://([^"]+\.gd)"\)', s):
        if not os.path.exists(os.path.join(GAME, path)):
            missing.setdefault(path, set())
CONST_OVERRIDES = {
    'KINDS': '[]', 'ITEM_SEAT': 'Vector3.ZERO', 'BRONZE': 'Color(0.63, 0.51, 0.33)', 'STOCK_AREA': '1.0',
    'ROLLER': '"roller"', 'COUNTERBASE': '"counterbase"', 'PIVOT': '"pivot"', 'BOOM': '"boom"', 'BALANCED_BOOM': '"balanced_boom"',
}
def const_value(c, path):
    if c in CONST_OVERRIDES: return CONST_OVERRIDES[c]
    if 'PROFILE' in c or c.endswith('_TABLE') or c.endswith('_KINDS'): return '{}'
    if c in ('KIND', 'NAME', 'ID'): return '"%s"' % os.path.basename(path)[:-3]
    if c in ('SIZE', 'EXTENTS', 'HALF_EXTENTS'): return 'Vector3(0.3, 0.3, 0.3)'
    if c.endswith('COLOR') or c.endswith('COLOUR'): return 'Color(0.8, 0.8, 0.8)'
    return '0.0'

FUNC_TYPES = [  # (predicate, type, value) first match wins
    (lambda f: f == 'describe', 'Dictionary', '{"mass": 1.0, "size": Vector3(0.3, 0.3, 0.3), "area": 1.0, "bounds": AABB(Vector3(-0.15, -0.15, -0.15), Vector3(0.3, 0.3, 0.3)), "connectors": []}'),
    (lambda f: f == 'cut_parameters', 'Array[Dictionary]', '[{}, {}]'),
    (lambda f: f == 'normalize', 'Dictionary', '{"wheel_profile": "offroad"}'),
    (lambda f: f in ('validate',), 'Variant', 'null'),
    (lambda f: f in ('applies',), 'bool', 'false'),
    (lambda f: f in ('definition',), 'Dictionary', '{}'),
    (lambda f: f.endswith('mesh') or f.startswith('mesh'), 'Mesh', 'BoxMesh.new()'),
    (lambda f: f in ('bounds', 'aabb') or f.endswith('_bounds'), 'AABB', 'AABB(Vector3(-0.15, -0.15, -0.15), Vector3(0.3, 0.3, 0.3))'),
    (lambda f: 'closest_point' in f or f.endswith('_point') or f.endswith('_offset'), 'Vector3', 'Vector3.ZERO'),
    (lambda f: f.startswith('same') or f.startswith('is_') or f.startswith('has_') or f.startswith('matches') or f.startswith('can_'), 'bool', 'false'),
    (lambda f: f in ('describe', 'label', 'caption') or f.endswith('_name') or f.endswith('_text'), 'String', '""'),
    (lambda f: f.endswith('pose') or f.endswith('transform'), 'Transform3D', 'Transform3D.IDENTITY'),
    (lambda f: f.endswith('basis'), 'Basis', 'Basis.IDENTITY'),
    (lambda f: f.endswith('shapes') or f.endswith('entries') or f.endswith('pieces') or f.endswith('supports') or f.endswith('list'), 'Array', '[]'),
    (lambda f: f in ('normalize', 'validate', 'cut_parameters', 'solution', 'two_link') or f.endswith('parameters') or f.endswith('_info'), 'Dictionary', '{}'),
    (lambda f: f.endswith('color') or f.endswith('colour'), 'Color', 'Color(0.8, 0.8, 0.8)'),
    (lambda f: f in ('stone', 'dark', 'bronze') or f.endswith('material'), 'Material', 'StandardMaterial3D.new()'),
    (lambda f: f.endswith('mass') or f.endswith('length') or f.endswith('radius') or f.endswith('height') or f.endswith('width'), 'float', '0.0'),
]
def func_type(f):
    for pred, t, v in FUNC_TYPES:
        if pred(f.lower()): return t, v
    return 'Variant', 'null'

os.makedirs(AUTO, exist_ok=True)
for path, aliases in sorted(missing.items()):
    if os.path.exists(os.path.join(STUBS, path)): continue
    funcs, consts, inner = set(), set(), set()
    for s in srcs.values():
        for a in aliases:
            for m in re.findall(r'\b%s\.([A-Za-z_]\w*)\s*\(' % a, s): funcs.add(m)
            for m in re.findall(r'\b%s\.([A-Za-z_]\w*)\b(?!\s*\()' % a, s): consts.add(m)
    consts -= funcs
    out = ['extends Node3D',
           '## AUTO-GENERATED harness stub for missing RaulsMod module %s (aliases: %s).' % (path, ', '.join(sorted(aliases))),
           '## Not game code: permissive placeholders so the real Wako scripts can load.']
    for c in sorted(consts):
        if c == 'new': continue
        if c.isupper() or c[0].isupper():
            out.append('const %s = %s' % (c, const_value(c, path)))
        else:
            out.append('static var %s = null' % c)
    for f in sorted(funcs):
        if f == 'new': continue
        rtype, rval = func_type(f)
        out.append('static func %s(...args: Array) -> %s: return %s' % (f, rtype, rval))
    dest = os.path.join(AUTO, path)
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    open(dest, 'w').write('\n'.join(out) + '\n')
    print('stub', path, len(funcs), 'funcs', len(consts), 'consts')
