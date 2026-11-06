#!/usr/bin/env python3
"""Generate Watch's offline name/identity catalog from the phone's source catalog.

No images are copied. Existing free-provider media references are preserved.
"""
import json
from collections import defaultdict
from pathlib import Path


# Keep this deliberate allowlist in sync with ExerciseCatalogMetadata.swift.
equipment_families = [
    (['Barbell', 'Olympic Barbell'], 'Barbell', {'barbell', 'olympic barbell'}),
    (['EZ Barbell', 'EZ Bar', 'EZ Curl Bar'], 'EZ Bar',
     {'ez barbell', 'ez-curl-bar', 'ez bar', 'ez curl bar'}),
    (['Dumbbell'], 'Dumbbell', {'dumbbell'}),
    (['Cable'], 'Cable', {'cable'}),
    (['Kettlebell'], 'Kettlebell', {'kettlebell'}),
    (['Resistance Band', 'Band'], 'Band', {'band', 'resistance band', 'exercise band'}),
    (['Smith Machine', 'Smith'], 'Smith Machine', {'smith machine'}),
    (['Trap Bar'], 'Trap Bar', {'trap bar'}),
    (['Landmine'], 'Landmine', {'landmine'}),
]
equipment_prefixes = sorted(
    [(prefix, suffix, equipment)
     for prefixes, suffix, equipment in equipment_families for prefix in prefixes],
    key=lambda rule: len(rule[0]), reverse=True)


def display_title(item):
    """Move only a verified equipment prefix, preserving source movement text."""
    title = item['title']
    if item['id'] >= 10000:
        return title
    for suffix in [' (male)', ' (female)']:
        if title.lower().endswith(suffix):
            title = title[:-len(suffix)]
            break
    if ':' in title:
        return title

    equipment = {key.lower() for key in item.get('equipment', [])}
    for prefix, suffix, accepted_equipment in equipment_prefixes:
        if equipment.isdisjoint(accepted_equipment):
            continue
        if title.lower().startswith(prefix.lower() + ' '):
            movement = title[len(prefix) + 1:]
            if movement:
                return f'{movement}: {suffix}'
    return title


root = Path(__file__).resolve().parents[1]
source = root / 'WorkoutDataKit/everkinetic-data'
legacy = json.loads((source / 'exercises.json').read_text())
updates = json.loads((source / 'opengym-text-templates.json').read_text())
by_id = {item['uuid']: item for item in legacy}
by_id.update({item['uuid']: item for item in updates})
for art in json.loads((source / 'legacy-art.json').read_text()):
    if not (by_id[art['uuid']].get('animation') or by_id[art['uuid']].get('image')):
        by_id[art['uuid']] = {**by_id[art['uuid']], 'image': art['image'], 'animation': art['animation']}
duplicates = {item['uuid'] for item in json.loads((source / 'catalog-duplicates.json').read_text())
               if item['uuid'] in by_id and item['keep'] in by_id}

reviewed_aliases = {}
for filename in ['hevy-template-aliases.json', 'hevy-aliases.json']:
    reviewed_aliases.update(json.loads((source / filename).read_text()))
aliases_by_id = defaultdict(set)
for alias, exercise_id in reviewed_aliases.items():
    aliases_by_id[exercise_id].add(alias)

proposed_titles = {item['uuid']: display_title(item) for item in by_id.values()}
title_groups = defaultdict(list)
for item in by_id.values():
    if item['id'] < 10000:
        title_groups[proposed_titles[item['uuid']].lower()].append(item)
collisions = {title: items for title, items in title_groups.items() if len(items) > 1}
for items in collisions.values():
    for item in items:
        proposed_titles[item['uuid']] = item['title']

# Retain the previous source-title ordering for equal display names.
source_order = sorted(by_id.values(), key=lambda item: item['title'].casefold())
result = []
for item in sorted(source_order, key=lambda item: proposed_titles[item['uuid']].casefold()):
    filename = item.get('animation') or item.get('image') or ''
    basename = Path(filename).stem
    media_id = basename.split('-', 1)[1] if '-' in basename and '/' not in filename else None
    entry = {'id': item['uuid'], 'name': proposed_titles[item['uuid']],
             'muscle': (item.get('primary') or [None])[0],
             'imageURL': f'https://static.exercisedb.dev/media/{media_id}.gif' if media_id else None}
    aliases = set(item.get('alias', [])) | aliases_by_id[item['uuid']]
    if entry['name'] != item['title']:
        aliases.add(item['title'])
    if aliases:
        entry['aliases'] = sorted(aliases)
    # Mirrors ExerciseCatalogMetadata.secondaryIDs; search on Watch still finds these.
    if item['uuid'] in duplicates or not (filename or item.get('pdf')):
        entry['listed'] = False
    result.append(entry)
destination = root / 'WatchIron Extension/WatchExerciseCatalog.json'
destination.write_text(json.dumps(result, ensure_ascii=False, separators=(',', ':')) + '\n')
assert len({entry['id'] for entry in result}) == len(result)
print(f'{len(result)} exercises; {destination.stat().st_size} bytes')
print(f"{sum(entry['name'] != by_id[entry['id']]['title'] for entry in result)} display titles changed")
for title, items in sorted(collisions.items()):
    print(f'Collision {title!r}: ' + '; '.join(
        f"{item['title']} ({item['uuid']})" for item in items))
