#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

info "Copy default config to conf"
cd /opt/CAPEv2
sudo chmod +x conf/copy_configs.sh
sudo conf/copy_configs.sh

warning "You need to modify some param in sandbox.conf to setup config automatically"
sudo python3 "$SCRIPT_DIR/cape_config.py" --base-dir "$SCRIPT_DIR"
