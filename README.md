# CAPEv2 Auto-Setup

Automated installer for a CAPEv2 sandbox running on Ubuntu 24.04 with a KVM
Windows guest.

```
┌─────────────────────────────────────────┐
│          🖥️  Platform                   │
│     Windows 11 (Physical Host)          │
│   ┌─────────────────────────────────┐   │
│   │  🧰 Platform Hypervisor        │   │
│   │     VMware Workstation          │   │
│   │   ┌─────────────────────────┐   │   │
│   │   │  🐧 Sandbox Host        │   │   │
│   │   │    Ubuntu 24.04 (KVM)    │   │   │
│   │   │   ┌─────────────────┐   │   │   │
│   │   │   │  🪟 Win10 Guest │   │   │   │
│   │   │   └─────────────────┘   │   │   │
│   │   └─────────────────────────┘   │   │
│   └─────────────────────────────────┘   │
└─────────────────────────────────────────┘
```

## Requirements

- **Outer hypervisor**: VMware Workstation / ESXi / VirtualBox with **nested
  virtualization enabled**. See
  [Nested Virtualization Guide](https://github.com/luckystars0612/Setting-Guide/blob/main/Nested_Virtualization_WSL_Setup_Vmware.md).
- **Host OS**: Ubuntu 24.04 LTS (tested), 22.04 also works.
- **CPU**: VT-x / AMD-V support, both exposed to the guest.
- **Python**: whatever the OS ships with (3.10 on 22.04, 3.12 on 24.04).
  No manual Python install needed — `cape2.sh` will set it up under the
  chosen package manager.
- **Package manager**: **uv only** (fast single binary from astral.sh).
  Poetry is **not** supported. If `uv` is missing, the script installs it
  with `curl -LsSf https://astral.sh/uv/install.sh | sh`.

## Layout

| File | Purpose |
|------|---------|
| `sandbox.conf` | Single source of truth for IPs / VM name / snapshot. |
| `cape_setup.sh` | Runs on the Ubuntu host. Installs KVM, CAPEv2, services. |
| `cape_config.py` | Patches CAPEv2 configs in `/opt/CAPEv2/conf` from `sandbox.conf`. |
| `predefined_configs/` | Templates copied to `/opt/CAPEv2/conf/`. |
| `sandbox_config.ps1` | Runs on the Windows VM. Disables protections, installs Python + agent. |

## Step 1 — configure `sandbox.conf`

Before anything else, edit [`sandbox.conf`](sandbox.conf) with your network:

```ini
[DEFAULT]
resultserver_ip        = 192.168.122.1    # CAPE host IP that the guest reaches
sandbox_ip             = 192.168.122.50   # static IP for the Windows guest
sandbox_names          = win10            # virt-manager VM name (also the kvm.conf section)
resultserver_interface = virbr0           # libvirt bridge the guest attaches to
snapshot               = clean_state      # snapshot name reverted before every analysis
```

> **Heads up**: the key is `sandbox_names` (plural). It matches CAPEv2's
> `machines = …` syntax, which can list multiple VMs separated by commas.

## Step 2 — install the CAPE host

```bash
sudo chmod +x cape_setup.sh
sudo ./cape_setup.sh
```

What happens:

1. KVM availability is checked — script aborts if nested virt is off.
2. `apt` packages: `libvirt`, `qemu-kvm`, `virt-manager`, `open-vm-tools`.
3. CAPEv2 is cloned to `/opt/CAPEv2` and `cape2.sh all` is run with
   `USE_UV=True`. Install log: `/opt/CAPEv2/installer/cape.log`.
4. If `uv` is not already installed, the script runs the official
   astral.sh installer:
   ```bash
   curl -LsSf https://astral.sh/uv/install.sh | sh
   ```
   then copies the binary to `/usr/local/bin/uv` so `cape2.sh`'s
   hard-coded path works.
5. A loud confirmation banner prints the detected uv version and path.
6. Optional deps (`oscrypto`, `flare-floss`, `chepy`, …) are installed via
   `uv pip`.
7. Default CAPE configs are copied to `/opt/CAPEv2/conf/`.
8. `cape_config.py` patches those configs in-place using `sandbox.conf`
   (templates in `predefined_configs/` are left untouched).
9. User `cape` is added to `libvirt` + `kvm` groups, services are
   restarted, and each one is checked with `systemctl is-active`.

### Debugging services

```bash
sudo systemctl stop cape.service
cd /opt/CAPEv2
sudo -u cape /usr/local/bin/uv run python3 cuckoo.py
```

Tail logs:

```bash
sudo journalctl -u cape.service -f
sudo journalctl -u cape-processor.service -f
```

## Step 3 — create the Windows VM

In **virt-manager** (or `virt-install`):

1. Create a Windows 10 / 11 VM with the **same name** as `sandbox_names`
   in `sandbox.conf`.
2. Attach the NIC to the bridge named `resultserver_interface`
   (default `virbr0`).
3. Boot, install Windows, apply updates, install any runtimes you want
   (`.NET`, `Java`, `Office`, browsers, …).
4. Shut the VM down.

## Step 4 — run `sandbox_config.ps1` inside the guest

In an **Administrator** PowerShell inside the VM:

```powershell
Set-ExecutionPolicy -ExecutionPolicy Unrestricted -Scope LocalMachine
.\sandbox_config.ps1
```

The script (with IPs already patched by `cape_config.py`):

- Detects the first physical "Up" adapter automatically.
- Sets a static IP, gateway, DNS (8.8.8.8 / 8.8.4.4).
- Disables Teredo, LLMNR, Defender, Firewall, Microsoft Store.
- Installs **Sysmon** with SwiftOnSecurity's config.
- Installs **Python 3.10.11 (32-bit)** to `C:\Python310` plus Pillow.
- Downloads `agent.py` to `C:\cape_agent.pyw` and registers
  `CAPE_Agent` as a scheduled task running as SYSTEM at logon.

> **Why 32-bit Python?** Many malware samples are 32-bit. The agent needs
> to inject into them, and a 32-bit agent can only inject into 32-bit
> processes.

## Step 5 — take the snapshot

After the VM reboots and the agent is running, shut it down and take a
**snapshot in virt-manager** whose name matches the `snapshot` field in
`sandbox.conf` (default: `clean_state`). CAPE will revert to this snapshot
before every analysis.

## Step 6 — submit a sample

The CAPE web UI is at:

```
http://<resultserver_ip>:8000
```

Submit a sample and watch the magic.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `cape.service` won't start | `cape` user not in `libvirt`/`kvm` group | `sudo usermod -aG libvirt,kvm cape && sudo systemctl restart cape.service` |
| VM not found by CAPE | VM name doesn't match `sandbox_names` | Rename VM in virt-manager to match `sandbox_names` |
| Result server unreachable | Guest can't reach `resultserver_ip` | Check `resultserver_interface`, IP routes, host firewall |
| `cape_config.py` says "not patched" | You edited `sandbox.conf` after first run | Just rerun `sudo python3 cape_config.py --base-dir .` |
| Static IP step fails in PowerShell | Wrong adapter name / DHCP conflict | Adapter is auto-detected now; rerun after confirming one "Up" adapter in `Get-NetAdapter` |

## Notes & limitations

- This wrapper only supports **Windows** guests via KVM. For Linux guests,
  edit `predefined_configs/kvm.conf` and change `platform = linux`.
- The predefined configs are minimal — adjust `web.conf`, `reporting.conf`
  etc. manually if you need bells and whistles.
- The script does **not** install runtimes like `.NET` or `Java` inside
  the guest — install them after `sandbox_config.ps1` finishes, before
  the snapshot.
- No cleanup of downloaded installers — they're in `%TEMP%` and `/tmp`.