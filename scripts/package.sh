#!/bin/bash
# Compile PillMusic et produit build/PillMusic.zip, prêt à être partagé ou publié en Release.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build.sh
rm -f build/PillMusic.zip
ditto -c -k --keepParent build/PillMusic.app build/PillMusic.zip
echo "📦 build/PillMusic.zip"
