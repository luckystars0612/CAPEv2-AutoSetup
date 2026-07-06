#!/usr/bin/env python3
"""cape_config.py — Patch CAPEv2 config files using values from sandbox.conf.

Source of truth: sandbox.conf (single file edited by the operator).
Targets: predefined_configs/*.conf copied to /opt/CAPEv2/conf/.

The patcher is regex-based on purpose: it preserves comments and original
formatting (Python's configparser strips them on read/write). It only
modifies the destination files in /opt/CAPEv2/conf/, never the templates
in this repo, so re-running with a different sandbox.conf is idempotent.
"""

import argparse
import configparser
import ipaddress
import re
import shutil
import sys
from pathlib import Path


REQUIRED_KEYS = (
    "resultserver_ip",
    "sandbox_ip",
    "sandbox_names",
    "resultserver_interface",
    "snapshot",
)


# ---------- sandbox.conf ------------------------------------------------------

def read_sandbox_config(sandbox_path: Path) -> dict:
    # `inline_comment_prefixes` lets sandbox.conf use `;` after a value
    # without that text being treated as part of the value.
    parser = configparser.ConfigParser(
        interpolation=None,
        inline_comment_prefixes=(";", "#"),
    )
    if not parser.read(sandbox_path):
        raise ValueError(f"Cannot read {sandbox_path}")
    if "DEFAULT" not in parser:
        raise ValueError(f"{sandbox_path} is missing [DEFAULT] section")

    raw = {k: parser["DEFAULT"].get(k, "").strip() for k in REQUIRED_KEYS}
    missing = [k for k, v in raw.items() if not v]
    if missing:
        raise ValueError(f"sandbox.conf is missing keys: {', '.join(missing)}")

    for ip_key in ("resultserver_ip", "sandbox_ip"):
        try:
            ipaddress.ip_address(raw[ip_key])
        except ValueError:
            raise ValueError(f"Invalid IP in sandbox.conf for '{ip_key}': {raw[ip_key]}")

    return raw


# ---------- in-file section-aware key replacement ----------------------------

_SECTION_RE = re.compile(r"^\s*\[([^\]]+)\]\s*$")
_COMMENT_OR_BLANK_RE = re.compile(r"^\s*(#|;|$)")


def replace_in_section(file_path: Path, section: str, key: str, new_value: str) -> bool:
    """Replace a single ``key = value`` line inside ``[section]``.

    Returns True if a replacement was made. Comments on the same line are kept.
    """
    text = file_path.read_text(encoding="utf-8")
    lines = text.split("\n")
    in_section = False
    key_re = re.compile(rf"^(\s*){re.escape(key)}\s*=\s*(.*?)(\s*[#;].*)?$")

    for i, line in enumerate(lines):
        sec_match = _SECTION_RE.match(line)
        if sec_match:
            in_section = sec_match.group(1).strip() == section
            continue
        if not in_section or _COMMENT_OR_BLANK_RE.match(line):
            continue
        m = key_re.match(line)
        if m:
            indent, _, tail = m.group(1), m.group(2), m.group(3) or ""
            lines[i] = f"{indent}{key} = {new_value}{tail}"
            file_path.write_text("\n".join(lines), encoding="utf-8")
            return True

    return False


def upsert_section(file_path: Path, section: str, defaults: dict) -> None:
    """Ensure ``[section]`` exists and all default keys are set."""
    text = file_path.read_text(encoding="utf-8")
    section_present = re.search(rf"^\s*\[{re.escape(section)}\]\s*$", text, re.MULTILINE)

    if not section_present:
        # Append the whole section at end of file.
        with file_path.open("a", encoding="utf-8") as fh:
            fh.write(f"\n[{section}]\n")
            for k, v in defaults.items():
                fh.write(f"{k} = {v}\n")
        return

    # Section exists — update each key, only creating ones that are missing.
    section_lines = re.findall(
        rf"^\s*\[{re.escape(section)}\].*?(?=^\s*\[|\Z)",
        text, re.MULTILINE | re.DOTALL,
    )
    if not section_lines:
        return
    body = section_lines[0]
    for k, v in defaults.items():
        if re.search(rf"^\s*{re.escape(k)}\s*=", body, re.MULTILINE):
            replace_in_section(file_path, section, k, v)
        else:
            # Key is missing — append it at the end of the section.
            append_kv_to_section(file_path, section, k, v)


def append_kv_to_section(file_path: Path, section: str, key: str, value: str) -> None:
    """Append ``key = value`` at the end of ``[section]``."""
    text = file_path.read_text(encoding="utf-8")
    lines = text.split("\n")
    in_target = False
    insert_idx = len(lines)
    for i, line in enumerate(lines):
        sec_match = _SECTION_RE.match(line)
        if sec_match:
            if in_target:
                # Start of next section — insert just before it.
                insert_idx = i
                break
            in_target = sec_match.group(1).strip() == section
    if in_target:
        lines.insert(insert_idx, f"{key} = {value}")
        file_path.write_text("\n".join(lines), encoding="utf-8")


# ---------- per-file patches --------------------------------------------------

def patch_auxiliary(dst: Path, cfg: dict) -> None:
    replace_in_section(dst, "auxiliary_modules", "windows_static_route_gateway", cfg["resultserver_ip"])
    replace_in_section(dst, "sniffer", "interface", cfg["resultserver_interface"])


def patch_cuckoo(dst: Path, cfg: dict) -> None:
    replace_in_section(dst, "resultserver", "ip", cfg["resultserver_ip"])


def patch_routing(dst: Path, cfg: dict) -> None:
    replace_in_section(dst, "routing", "internet", cfg["resultserver_interface"])


def patch_kvm(dst: Path, cfg: dict) -> None:
    replace_in_section(dst, "kvm", "machines", cfg["sandbox_names"])
    replace_in_section(dst, "kvm", "interface", cfg["resultserver_interface"])
    upsert_section(dst, cfg["sandbox_names"], {
        "label": cfg["sandbox_names"],
        "platform": "windows",
        "ip": cfg["sandbox_ip"],
        "arch": "x64",
        "snapshot": cfg["snapshot"],
        "resultserver_ip": cfg["resultserver_ip"],
    })


def patch_powershell(ps_path: Path, cfg: dict) -> None:
    text = ps_path.read_text(encoding="utf-8")
    text = re.sub(r'(\$sandbox_ip\s*=\s*)"[^"]*"', f'\\1"{cfg["sandbox_ip"]}"', text)
    text = re.sub(r'(\$cape_ip\s*=\s*)"[^"]*"', f'\\1"{cfg["resultserver_ip"]}"', text)
    ps_path.write_text(text, encoding="utf-8")


PATCHERS = {
    "auxiliary.conf": patch_auxiliary,
    "cuckoo.conf": patch_cuckoo,
    "kvm.conf": patch_kvm,
    "routing.conf": patch_routing,
}


# ---------- main --------------------------------------------------------------

def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--base-dir", required=True, type=Path,
                    help="Repo directory containing sandbox.conf and predefined_configs/")
    ap.add_argument("--dst-dir", default=Path("/opt/CAPEv2/conf"), type=Path,
                    help="Destination CAPE config directory (default: /opt/CAPEv2/conf)")
    args = ap.parse_args()

    base = args.base_dir.resolve()
    src_dir = base / "predefined_configs"
    sandbox_conf = base / "sandbox.conf"
    ps_script = base / "sandbox_config.ps1"

    if not sandbox_conf.is_file():
        print(f"❌ sandbox.conf not found at {sandbox_conf}", file=sys.stderr)
        return 1
    if not src_dir.is_dir():
        print(f"❌ predefined_configs/ not found at {src_dir}", file=sys.stderr)
        return 1

    try:
        cfg = read_sandbox_config(sandbox_conf)
    except (ValueError, OSError) as e:
        print(f"❌ {e}", file=sys.stderr)
        return 1
    print(f"ℹ️  Loaded sandbox.conf: {cfg}")

    args.dst_dir.mkdir(parents=True, exist_ok=True)

    config_files = [
        "auxiliary.conf", "cuckoo.conf", "kvm.conf",
        "reporting.conf", "routing.conf", "web.conf",
    ]

    for cf in config_files:
        src = src_dir / cf
        dst = args.dst_dir / cf

        if not src.is_file():
            print(f"⚠️  {cf} not in predefined_configs/, skipping")
            continue

        try:
            # 1. Copy the original template to the destination untouched.
            shutil.copy2(src, dst)
            # 2. Apply the patch in-place on the destination only.
            if cf in PATCHERS:
                PATCHERS[cf](dst, cfg)
            print(f"✔️  {cf} → {dst}")
        except Exception as e:
            print(f"❌ Error processing {cf}: {e}", file=sys.stderr)
            return 1

    # Patch the PowerShell script in the repo (the user copies it to the guest).
    if ps_script.is_file():
        try:
            patch_powershell(ps_script, cfg)
            print(f"✔️  sandbox_config.ps1 patched (sandbox_ip={cfg['sandbox_ip']}, "
                  f"cape_ip={cfg['resultserver_ip']})")
        except Exception as e:
            print(f"❌ Error patching sandbox_config.ps1: {e}", file=sys.stderr)
            return 1
    else:
        print(f"❌ sandbox_config.ps1 not found at {ps_script}", file=sys.stderr)
        return 1

    print("✅ All configs updated")
    return 0


if __name__ == "__main__":
    sys.exit(main())