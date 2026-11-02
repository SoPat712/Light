#!/usr/bin/env python3
"""Generate Watch's offline name/identity catalog from the phone's source catalog.

No images are copied. Existing free-provider media references are preserved.
"""
import json
from pathlib import Path

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
result = []
for item in sorted(by_id.values(), key=lambda item: item['title'].casefold()):
    filename = item.get('animation') or item.get('image') or ''
    basename = Path(filename).stem
    media_id = basename.split('-', 1)[1] if '-' in basename and '/' not in filename else None
    entry = {'id': item['uuid'], 'name': item['title'],
             'muscle': (item.get('primary') or [None])[0],
             'imageURL': f'https://static.exercisedb.dev/media/{media_id}.gif' if media_id else None}
    # Mirrors ExerciseCatalogMetadata.secondaryIDs; search on Watch still finds these.
    if item['uuid'] in duplicates or not (filename or item.get('pdf')):
        entry['listed'] = False
    result.append(entry)
destination = root / 'WatchIron Extension/WatchExerciseCatalog.json'
destination.write_text(json.dumps(result, ensure_ascii=False, separators=(',', ':')) + '\n')
assert len({entry['id'] for entry in result}) == len(result)
print(f'{len(result)} exercises; {destination.stat().st_size} bytes')
