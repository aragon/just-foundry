#!/usr/bin/env bash
# ipfs-pin.sh — pin a file to IPFS via Pinata
# Usage: ipfs-pin.sh <file>  (requires PINATA_JWT in environment)
set -euo pipefail

FILE="$1"
[ -f "$FILE" ] || { echo "Error: File not found: $FILE" >&2; exit 1; }
[ -n "${PINATA_JWT:-}" ] || { echo "Error: PINATA_JWT is not set. Add it to .vars.yaml or .env" >&2; exit 1; }

RESPONSE=$(curl -sS -X POST "https://api.pinata.cloud/pinning/pinFileToIPFS" \
    -H "Authorization: Bearer $PINATA_JWT" \
    -F "file=@$FILE")

CID=$(echo "$RESPONSE" | jq -r '.IpfsHash // empty')
[ -n "$CID" ] || { echo "Error: Upload failed. Response: $RESPONSE" >&2; exit 1; }

echo "ipfs://$CID"
