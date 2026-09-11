#!/usr/bin/env python3
import json, sys
from pathlib import Path

src, dst, variant = sys.argv[1:4]
components=[]
for line in Path(src).read_text().splitlines():
    if not line.strip():
        continue
    try:
        name, version = line.split('\t',1)
    except ValueError:
        continue
    base_name=name.split(':',1)[0]
    components.append({
        "type":"library",
        "name":base_name,
        "version":version,
        "purl":f"pkg:deb/debian/{base_name}@{version}",
        "properties":[{"name":"debian:binary-package","value":name}]
    })
components.sort(key=lambda x:(x["name"],x["version"]))
doc={
    "bomFormat":"CycloneDX",
    "specVersion":"1.6",
    "version":1,
    "metadata":{"component":{"type":"operating-system","name":f"frr-appliance-{variant}"}},
    "components":components,
}
Path(dst).write_text(json.dumps(doc, indent=2, sort_keys=True)+"\n")
