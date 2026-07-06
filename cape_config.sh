#!/bin/bash
#
# cape_config.sh — Re-run cape_config.py against /opt/CAPEv2/conf/
#
# Use this when you edit sandbox.conf AFTER the initial install and want to
# propagate the new values to /opt/CAPEv2/conf without re-installing CAPEv2.
#
# It does NOT touch the original templates in this repo's predefined_configs/.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "ℹ️  Copying default CAPEv2 configs to /opt/CAPEv2/conf/..."
cd /opt/CAPEv2
sudo chmod +x conf/copy_configs.sh
sudo ./conf/copy_configs.sh

echo "ℹ️  Patching configs from sandbox.conf..."
sudo python3 "$SCRIPT_DIR/cape_config.py" --base-dir "$SCRIPT_DIR"

echo "ℹ️  Restarting CAPE services..."
sudo systemctl restart cape.service cape-processor.service cape-web.service cape-rooter.service

echo "✔️ Done. Check service status with: sudo systemctl status cape.service"