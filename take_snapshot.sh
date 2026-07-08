#!/usr/bin/env bash
#
# take_snapshot.sh - take the stable "clean_state" libvirt snapshot for CAPEv2.
#
# Run this on the Ubuntu CAPE HOST (not in the guest). Snapshots are a
# hypervisor operation - the guest cannot snapshot itself.
#
# It reads the VM name / snapshot name / guest IP from sandbox.conf, makes sure
# the guest is running and the CAPE agent is reachable, then takes a LIVE
# internal snapshot (disk + memory) so CAPE reverts to a VM that already has the
# agent running in the interactive session.
#
# Usage:
#   ./take_snapshot.sh                 # uses ./sandbox.conf
#   ./take_snapshot.sh /path/sandbox.conf
#   FORCE=1 ./take_snapshot.sh         # skip the "agent reachable" gate
#
set -euo pipefail

CONF="${1:-sandbox.conf}"
AGENT_PORT="${AGENT_PORT:-8000}"
WAIT_SECS="${WAIT_SECS:-120}"

die() { echo "ERROR: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

[ -f "$CONF" ] || die "config not found: $CONF"
have virsh || die "virsh not installed (libvirt-clients)."

# --- read keys from the [DEFAULT] section of sandbox.conf --------------------
getconf() { grep -E "^[[:space:]]*$1[[:space:]]*=" "$CONF" | head -n1 | cut -d= -f2- | xargs; }
VM="$(getconf sandbox_names | cut -d, -f1)"   # first VM if several are listed
SNAP="${SNAP:-$(getconf snapshot)}"           # env SNAP overrides sandbox.conf
IP="$(getconf sandbox_ip)"

[ -n "$VM" ]   || die "sandbox_names not set in $CONF"
[ -n "$SNAP" ] || die "snapshot not set in $CONF (or pass SNAP=clean_state)"

# The CAPE service reverts to the name in kvm.conf, so make sure we match it.
KVMCONF="${KVMCONF:-/opt/CAPEv2/conf/kvm.conf}"
if [ -f "$KVMCONF" ]; then
    KVM_SNAP="$(grep -E '^[[:space:]]*snapshot[[:space:]]*=' "$KVMCONF" | head -n1 | cut -d= -f2- | xargs || true)"
    if [ -n "$KVM_SNAP" ] && [ "$KVM_SNAP" != "$SNAP" ]; then
        echo "WARNING: kvm.conf has snapshot='$KVM_SNAP' but this run would create '$SNAP'." >&2
        echo "         CAPE reverts to '$KVM_SNAP' - the names must match, or CAPE won't find it." >&2
        read -r -p "Use kvm.conf's '$KVM_SNAP' instead? (Y/n) " a
        [ "$a" = "n" ] || [ "$a" = "N" ] || SNAP="$KVM_SNAP"
    fi
fi
echo "VM=$VM  snapshot=$SNAP  guest=$IP:$AGENT_PORT"

# --- domain must exist ------------------------------------------------------
virsh dominfo "$VM" >/dev/null 2>&1 || die "domain '$VM' not defined in libvirt. Fix sandbox_names."

# --- internal snapshots need a qcow2 disk -----------------------------------
DISK="$(virsh domblklist "$VM" --details 2>/dev/null | awk '$2=="disk"{print $4; exit}')"
if [ -n "${DISK:-}" ] && have qemu-img; then
    FMT="$(qemu-img info "$DISK" 2>/dev/null | awk -F': ' '/file format/{print $2}')" || true
    if [ -n "${FMT:-}" ] && [ "$FMT" != "qcow2" ]; then
        echo "WARNING: disk format is '$FMT', not qcow2 - internal snapshots may fail." >&2
        echo "         Convert with: qemu-img convert -O qcow2 old.img new.qcow2" >&2
    fi
fi

# --- ensure the guest is running --------------------------------------------
STATE="$(virsh domstate "$VM" 2>/dev/null || echo unknown)"
if [ "$STATE" != "running" ]; then
    echo "Guest is '$STATE' - starting it..."
    virsh start "$VM" >/dev/null || die "could not start '$VM'."
fi

# --- wait for the CAPE agent to answer (proxy for 'guest fully ready') -------
agent_up() {
    if have nc; then nc -z -w2 "$IP" "$AGENT_PORT" >/dev/null 2>&1; return $?; fi
    (exec 3<>"/dev/tcp/$IP/$AGENT_PORT") >/dev/null 2>&1 && { exec 3>&- 3<&-; return 0; } || return 1
}
if [ -n "$IP" ] && [ "${FORCE:-0}" != "1" ]; then
    echo -n "Waiting up to ${WAIT_SECS}s for the agent on $IP:$AGENT_PORT "
    ok=0
    for _ in $(seq 1 "$WAIT_SECS"); do
        if agent_up; then ok=1; break; fi
        echo -n "."; sleep 1
    done
    echo
    if [ "$ok" != "1" ]; then
        echo "Agent not reachable. In the guest, log in as the analysis user and run:" >&2
        echo "    .\\sandbox_config.ps1 -Verify" >&2
        echo "Re-run with FORCE=1 to snapshot anyway (not recommended)." >&2
        exit 1
    fi
    echo "[OK] Agent is reachable."
else
    echo "Skipping agent reachability check."
fi

read -r -p "Take snapshot '$SNAP' of '$VM' now? Existing one with that name is replaced. (y/N) " ans
[ "$ans" = "y" ] || [ "$ans" = "Y" ] || { echo "Aborted."; exit 0; }

# --- replace any existing snapshot of the same name -------------------------
if virsh snapshot-list "$VM" --name 2>/dev/null | grep -qx "$SNAP"; then
    echo "Deleting existing snapshot '$SNAP'..."
    virsh snapshot-delete "$VM" "$SNAP" >/dev/null || die "could not delete old snapshot."
fi

# --- take a LIVE internal snapshot (disk + RAM) so revert keeps agent up -----
echo "Creating snapshot '$SNAP'..."
virsh snapshot-create-as "$VM" "$SNAP" \
    --description "CAPE clean state ($(date -u +%FT%TZ))" \
    --atomic >/dev/null || die "snapshot-create-as failed."

echo
virsh snapshot-info "$VM" "$SNAP"
echo
echo "[DONE] Snapshot '$SNAP' created for '$VM'."
echo "Make sure kvm.conf / sandbox.conf reference snapshot=$SNAP, then submit a sample."