#!/usr/bin/env bash

set -euo pipefail

cat <<'EOF'
Recommended restore image matching AVPBooter mBoot-18000.121.3:
  Product: VirtualMac2,1
  Version: macOS 26.5.2 (25F84)
  Name: UniversalMac_26.5.2_25F84_Restore.ipsw
  Size: 19,769,902,281 bytes (about 18.41 GiB)
  SHA-1: a6dec8ec379533876d8ceea3d82ce482034e24ae
  SHA-256: 065abd295a1a456a46c1155217eab92ee95816520ec9aeed83f249f074f68a04
  URL: https://updates.cdn-apple.com/2026SpringFCS/fullrestores/140-24263/B95838F0-6815-4F0B-A039-156526C081AD/UniversalMac_26.5.2_25F84_Restore.ipsw

This command only prints metadata; it does not download the IPSW.
EOF
