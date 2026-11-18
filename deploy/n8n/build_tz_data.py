#!/usr/bin/env python3
"""Regenerates tz_data.json: the Gate's fallback timezone lookups (US ZIP prefix and NANP area code -> IANA zones).

  pip install --target /tmp/pylib phonenumbers zipcodes && PYTHONPATH=/tmp/pylib deploy/n8n/build_tz_data.py

An entry lists every zone a prefix covers; the Gate requires the legal window to be open in all of them.
Format: {"area": {"<zone>|<zone>": "201 202 …"}, "zip3": {…}} (prefixes grouped by zone set to keep the file small).
"""
import collections
import json
import os

import zipcodes
from phonenumbers.tzdata import TIMEZONE_DATA


def grouped(prefix_zones):
    groups = collections.defaultdict(list)
    for prefix, zones in prefix_zones.items():
        groups['|'.join(sorted(zones))].append(prefix)
    return {zones: ' '.join(sorted(prefixes)) for zones, prefixes in sorted(groups.items())}


area = collections.defaultdict(set)
for prefix, zones in TIMEZONE_DATA.items():
    if prefix.startswith('1') and len(prefix) >= 4:
        area[prefix[1:4]].update(z for z in zones if '/' in z)
area = {code: zones for code, zones in area.items() if zones}

zip3 = collections.defaultdict(set)
for z in zipcodes.list_all():
    if z.get('timezone') and z.get('active', True):
        zip3[z['zip_code'][:3]].add(z['timezone'])

out = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'tz_data.json')
with open(out, 'w') as f:
    json.dump({'area': grouped(area), 'zip3': grouped(zip3)}, f, indent=1, sort_keys=True)
    f.write('\n')
print(f'wrote {out}: {len(area)} area codes, {len(zip3)} zip prefixes')
