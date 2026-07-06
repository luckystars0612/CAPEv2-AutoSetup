#!/bin/bash
#
# cape_setup.sh — Automated CAPEv2 host installer for KVM-based sandbox.
#
# Tested on: Ubuntu 24.04 LTS, KVM with nested virtualization enabled in
# the outer hypervisor (VMware Workstation / ESXi).
#
# What this script does:
#   1. Installs KVM, libvirt, virt-manager, VMware guest tools.
#   2. Clones CAPEv2 to /opt/CAPEv2 and runs cape2.sh (with uv).
#   3. Installs optional CAPE dependencies.
#   4. Copies predefined configs from this repo to /opt/CAPEv2/conf,
#      patches them with values from sandbox.conf.
#   5. Restarts CAPE systemd services and verifies they are running.
#
# Required before running:
#   - Edit sandbox.conf with your network/VM values.
#   - Enable nested virtualization on the outer hypervisor.
#   - Run as a user with sudo rights (or as root).

set -uo pipefail

# --- pretty logging ----------------------------------------------------------
success() { echo -e "\e[32m✔️  $1\e[0m"; }
error()   { echo -e "\e[31m❌  $1\e[0m"; }
info()    { echo -e "\e[34mℹ️  $1\e[0m"; }
warning() { echo -e "\e[33m⚠️  $1\e[0m"; }
step()    { echo -e "\e[1;36m▶ $1\e[0m"; }

# --- root check --------------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
    error "This script must be run as root (sudo ./cape_setup.sh)."
    exit 1
fi

# --- script directory --------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- banner ------------------------------------------------------------------
info "CAPE Sandbox Auto-Setup"
cat <<'EOF'
┌─────────────────────────────────────────┐
│          🖥️  Platform                   │
│     Windows 11 (Physical Host)          │
│   ┌─────────────────────────────────┐   │
│   │  🧰 Platform Hypervisor        │   │
│   │     VMware Workstation          │   │
│   │   ┌─────────────────────────┐   │   │
│   │   │  🐧 Sandbox Host        │   │   │
│   │   │    Ubuntu 24.04         │   │   │
│   │   │   ┌─────────────────┐   │   │   │
│   │   │   │ ⚙️  KVM          │   │   │   │
│   │   │   │   🪟 Win10 Guest │   │   │   │
│   │   │   └─────────────────┘   │   │   │
│   │   └─────────────────────────┘   │   │
│   └─────────────────────────────────┘   │
└─────────────────────────────────────────┘
EOF

# --- KVM availability check (fail fast) -------------------------------------
step "Checking KVM availability..."
if ! command -v kvm-ok >/dev/null 2>&1; then
    warning "kvm-ok not installed yet — installing cpu-checker"
    apt-get install -y cpu-checker >/dev/null
fi
if ! kvm-ok 2>/dev/null | grep -q "KVM acceleration can be used"; then
    error "KVM is not available. Enable nested virtualization in the outer hypervisor and reboot."
    error "See: https://www.linux-kvm.org/page/Nested_GVT-g"
    exit 1
fi
success "KVM acceleration available"

# --- sandbox.conf validation ------------------------------------------------
if [ ! -f "$SCRIPT_DIR/sandbox.conf" ]; then
    error "sandbox.conf not found in $SCRIPT_DIR"
    exit 1
fi
SANDBOX_VALIDATION=$(python3 - "$SCRIPT_DIR/sandbox.conf" <<'PYEOF' 2>&1
import sys, configparser, ipaddress
path = sys.argv[1]
c = configparser.ConfigParser(interpolation=None, inline_comment_prefixes=(";", "#"))
if not c.read(path):
    sys.exit(f"Cannot read {path}")
if "DEFAULT" not in c:
    sys.exit("Missing [DEFAULT] section in sandbox.conf")
required = ["resultserver_ip", "sandbox_ip", "sandbox_names",
            "resultserver_interface", "snapshot"]
missing = [k for k in required if not c["DEFAULT"].get(k, "").strip()]
if missing:
    sys.exit(f"Missing keys in sandbox.conf: {', '.join(missing)}")
for k in ("resultserver_ip", "sandbox_ip"):
    try:
        ipaddress.ip_address(c["DEFAULT"][k].strip())
    except ValueError:
        sys.exit(f"Invalid IP for '{k}': {c['DEFAULT'][k]!r}")
PYEOF
)
if [ -n "$SANDBOX_VALIDATION" ]; then
    error "sandbox.conf validation failed: $SANDBOX_VALIDATION"
    exit 1
fi
success "sandbox.conf validated"

# --- base packages -----------------------------------------------------------
step "Updating apt and installing base packages..."
apt-get update
apt-get install -y \
    git curl wget ca-certificates gnupg lsb-release \
    open-vm-tools open-vm-tools-desktop \
    bridge-utils cpu-checker \
    libvirt-dev libvirt-clients libvirt-daemon \
    qemu-system-x86 qemu-kvm qemu-utils \
    virt-manager

success "Base packages installed"

# --- CAPEv2 source -----------------------------------------------------------
CAPE_ROOT="/opt/CAPEv2"
if [ -d "$CAPE_ROOT" ]; then
    warning "$CAPE_ROOT already exists — skipping clone (delete it for a clean install)"
else
    step "Cloning CAPEv2 to $CAPE_ROOT..."
    git clone https://github.com/kevoreilly/CAPEv2.git "$CAPE_ROOT"
fi

# --- Ensure uv is installed (uv ONLY, no poetry fallback) ------------------
step "Ensuring uv is installed..."

# Look for an existing uv install in the two common locations.
PYTHON_MGR=""
if [ -x /usr/local/bin/uv ]; then
    PYTHON_MGR="/usr/local/bin/uv"
elif [ -x "$HOME/.local/bin/uv" ]; then
    PYTHON_MGR="$HOME/.local/bin/uv"
    export PATH="$HOME/.local/bin:$PATH"
fi

if [ -z "$PYTHON_MGR" ]; then
    info "uv not found — installing via astral.sh installer"
    # Use exactly the install command recommended by the uv docs.
    # On macOS and Linux.
    curl -LsSf https://astral.sh/uv/install.sh | sh
    if [ -x "$HOME/.local/bin/uv" ]; then
        PYTHON_MGR="$HOME/.local/bin/uv"
        export PATH="$HOME/.local/bin:$PATH"
    fi
fi

# cape2.sh hard-codes PYTHON_MGR=/usr/local/bin/uv when USE_UV=True, so make
# sure uv is reachable at that system path (copy, don't symlink, so it works
# even when /root/.local/bin has odd perms).
if [ -x "$HOME/.local/bin/uv" ] && [ ! -x /usr/local/bin/uv ]; then
    install -m 0755 "$HOME/.local/bin/uv" /usr/local/bin/uv
fi

if [ -x /usr/local/bin/uv ]; then
    PYTHON_MGR="/usr/local/bin/uv"
fi

if [ -z "$PYTHON_MGR" ] || [ ! -x "$PYTHON_MGR" ]; then
    error "uv installation failed. Install manually with:"
    error "    curl -LsSf https://astral.sh/uv/install.sh | sh"
    exit 1
fi

# --- Confirm uv usage (printed loudly so the operator sees it) --------------
UV_VERSION=$("$PYTHON_MGR" --version 2>&1)
if [ -z "$UV_VERSION" ]; then
    error "uv at $PYTHON_MGR does not respond to --version"
    exit 1
fi
echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║  ✓ CONFIRMED: using uv (NOT poetry)                            ║"
echo "║    Version : $UV_VERSION"
echo "║    Path    : $PYTHON_MGR"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

# --- Run cape2.sh with uv ---------------------------------------------------
step "Running cape2.sh with uv (this may take a while)..."
cd "$CAPE_ROOT/installer"
chmod +x cape2.sh
# USE_UV=True tells cape2.sh to install and use uv instead of poetry.
USE_UV=True bash ./cape2.sh all 2>&1 | tee "$CAPE_ROOT/installer/cape.log"
CAPE_INSTALL_RC=${PIPESTATUS[0]}
if [ "$CAPE_INSTALL_RC" -ne 0 ]; then
    error "cape2.sh failed with exit code $CAPE_INSTALL_RC. See $CAPE_ROOT/installer/cape.log"
    exit 1
fi
success "cape2.sh completed"

# --- Re-confirm uv after cape2.sh -------------------------------------------
if [ ! -x "$PYTHON_MGR" ]; then
    # cape2.sh may have moved uv; re-resolve.
    for p in /usr/local/bin/uv "$HOME/.local/bin/uv"; do
        if [ -x "$p" ]; then PYTHON_MGR="$p"; break; fi
    done
    if [ ! -x "$PYTHON_MGR" ]; then
        error "uv disappeared after cape2.sh — aborting"
        exit 1
    fi
fi
UV_VERSION=$("$PYTHON_MGR" --version 2>&1)
success "Still using uv $UV_VERSION at $PYTHON_MGR"

# --- Optional dependencies ---------------------------------------------------
step "Installing optional CAPE dependencies (may take several minutes)..."
cd "$CAPE_ROOT"
$PYTHON_MGR pip install --quiet \
    "git+https://github.com/wbond/oscrypto.git@1547f535001ba568b239b8797465536759c742a3" \
    certvalidator asn1crypto mscerts \
    "git+https://github.com/DissectMalware/batch_deobfuscator" \
    "git+https://github.com/CAPESandbox/httpreplay" \
    chepy python-magic libvirt-python \
    flare-floss || warning "Some optional deps failed — check output above"
success "Optional dependencies installed"

# --- Default config copy + our customization --------------------------------
step "Copying default CAPEv2 configs to $CAPE_ROOT/conf/..."
cd "$CAPE_ROOT"
chmod +x conf/copy_configs.sh
./conf/copy_configs.sh

step "Patching configs from sandbox.conf..."
if ! python3 "$SCRIPT_DIR/cape_config.py" --base-dir "$SCRIPT_DIR" --dst-dir "$CAPE_ROOT/conf"; then
    error "cape_config.py failed — see errors above"
    exit 1
fi
success "Configs patched"

# --- Cape user & group setup -------------------------------------------------
step "Verifying 'cape' user..."
if ! id cape >/dev/null 2>&1; then
    error "User 'cape' was not created by cape2.sh. CAPE install is broken."
    exit 1
fi
# Add cape to libvirt/kvm so it can manage VMs without sudo.
# systemd picks up supplementary groups when starting cape.service, so a
# restart below is enough — no need to log in/out.
usermod -aG libvirt,kvm cape
success "User 'cape' added to libvirt,kvm (effective on next cape.service start)"

# --- Restart CAPE services ---------------------------------------------------
step "Reloading systemd and restarting CAPE services..."
systemctl daemon-reload
SERVICES=(cape.service cape-processor.service cape-web.service cape-rooter.service)
for svc in "${SERVICES[@]}"; do
    systemctl restart "$svc" || warning "$svc failed to restart — check 'journalctl -u $svc'"
done

# --- Verify ------------------------------------------------------------------
step "Verifying CAPE services..."
sleep 5
ALL_OK=true
for svc in "${SERVICES[@]}"; do
    if systemctl is-active --quiet "$svc"; then
        success "$svc is running"
    else
        error "$svc is NOT running"
        ALL_OK=false
    fi
done

if [ "$ALL_OK" = false ]; then
    warning "One or more services failed. Investigate with:"
    echo "    sudo journalctl -u cape.service -n 100 --no-pager"
    echo "    sudo journalctl -u cape-processor.service -n 100 --no-pager"
    exit 1
fi

# --- Done --------------------------------------------------------------------
success "CAPE host installation complete!"
cat <<EOF

📋 Next steps:
   1. Open virt-manager, create a Windows 10/11 VM named:
        $(grep -E '^sandbox_names' "$SCRIPT_DIR/sandbox.conf" | cut -d= -f2 | xargs)
   2. Configure a static IP matching 'sandbox_ip' in sandbox.conf.
   3. Copy this repo's sandbox_config.ps1 to the Windows VM and run it as Administrator.
   4. Install Python 3.10.11 (32-bit) and any runtimes you want (.NET, Java, Office, ...).
   5. Take a snapshot matching the 'snapshot' name in sandbox.conf.
   6. Access CAPE web UI at http://$(grep -E '^resultserver_ip' "$SCRIPT_DIR/sandbox.conf" | cut -d= -f2 | xargs):8000

🔧 Debug mode (if a service won't start):
   sudo systemctl stop cape.service
   cd $CAPE_ROOT
   sudo -u cape $PYTHON_MGR run python3 cuckoo.py
EOF