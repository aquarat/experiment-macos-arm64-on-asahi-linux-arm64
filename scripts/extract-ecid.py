#!/usr/bin/env python3

import base64
import json
import plistlib
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {Path(sys.argv[0]).name} VM_JSON", file=sys.stderr)
        return 2

    config = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
    machine_id = plistlib.loads(base64.b64decode(config["machineId"]))
    ecid = machine_id.get("ECID")
    if not isinstance(ecid, int) or ecid <= 0:
        raise ValueError("machineId plist has no positive integer ECID")
    print(ecid)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
