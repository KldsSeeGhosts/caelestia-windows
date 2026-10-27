#!/usr/bin/env python3
import glob
import json
import os
import sys

usage_dir = os.path.join(os.path.expanduser(os.environ.get("XDG_STATE_HOME", "~/.local/state")), "omarchy/agents/usage")
records = []
for f in sorted(glob.glob(f"{usage_dir}/*.json")):
    try:
        # utf-8-sig also accepts records saved with a UTF-8 BOM.
        with open(f, "r", encoding="utf-8-sig") as fp:
            data = json.load(fp)
            if isinstance(data, dict):
                records.append(data)
    except Exception:
        pass
print(json.dumps(records))
