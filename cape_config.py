import argparse
import configparser
import os
import shutil
import ipaddress
import sys
import re

def validate_ip(ip):
    try:
        ipaddress.ip_address(ip)
        return True
    except ValueError:
        return False

def read_sandbox_config(sandbox_path):
    config = configparser.ConfigParser()
    config.read(sandbox_path)
    if 'DEFAULT' not in config:
        raise ValueError("Invalid sandbox.conf: Missing DEFAULT section")
    
    required_keys = ['resultserver_ip', 'sandbox_ip', 'sandbox_names', 'resultserver_interface', 'snapshot']
    for key in required_keys:
        if key not in config['DEFAULT']:
            raise ValueError(f"Missing {key} in sandbox.conf")
    
    if not validate_ip(config['DEFAULT']['resultserver_ip']):
        raise ValueError(f"Invalid resultserver_ip: {config['DEFAULT']['resultserver_ip']}")
    if not validate_ip(config['DEFAULT']['sandbox_ip']):
        raise ValueError(f"Invalid sandbox_ip: {config['DEFAULT']['sandbox_ip']}")
    
    return {
        'resultserver_ip': config['DEFAULT']['resultserver_ip'],
        'sandbox_ip': config['DEFAULT']['sandbox_ip'],
        'sandbox_names': config['DEFAULT']['sandbox_names'],
        'resultserver_interface': config['DEFAULT']['resultserver_interface'],
        'snapshot': config['DEFAULT']['snapshot']
    }

def update_auxiliary_conf(file_path, resultserver_ip, resultserver_interface):
    config = configparser.ConfigParser()
    config.read(file_path)
    
    if 'auxiliary_modules' not in config or 'sniffer' not in config:
        raise ValueError("Invalid auxiliary.conf: Missing required sections")
    
    config['auxiliary_modules']['windows_static_route_gateway'] = resultserver_ip
    config['sniffer']['interface'] = resultserver_interface
    
    with open(file_path, 'w') as f:
        config.write(f)

def update_cuckoo_conf(file_path, resultserver_ip):
    config = configparser.ConfigParser()
    config.read(file_path)
    
    if 'resultserver' not in config:
        raise ValueError("Invalid cuckoo.conf: Missing resultserver section")
    
    config['resultserver']['ip'] = resultserver_ip
    
    with open(file_path, 'w') as f:
        config.write(f)

def update_kvm_conf(file_path, sandbox_names, resultserver_interface, sandbox_ip, resultserver_ip, snapshot):
    config = configparser.ConfigParser()
    config.read(file_path)
    
    if 'kvm' not in config:
        raise ValueError("Invalid kvm.conf: Missing kvm section")
    
    config['kvm']['machines'] = sandbox_names
    config['kvm']['interface'] = resultserver_interface
    
    # Update or create machine-specific section
    if sandbox_names in config:
        config[sandbox_names] = {
            'label': sandbox_names,
            'platform': config[sandbox_names].get('platform', 'windows'),
            'ip': sandbox_ip,
            'arch': config[sandbox_names].get('arch', 'x64'),
            'snapshot': snapshot,
            'resultserver_ip': resultserver_ip
        }
    else:
        config[sandbox_names] = {
            'label': sandbox_names,
            'platform': 'windows',
            'ip': sandbox_ip,
            'arch': 'x64',
            'snapshot': snapshot,
            'resultserver_ip': resultserver_ip
        }
    
    with open(file_path, 'w') as f:
        config.write(f)

def update_routing_conf(file_path, resultserver_interface):
    config = configparser.ConfigParser()
    config.read(file_path)
    
    if 'routing' not in config:
        raise ValueError("Invalid routing.conf: Missing routing section")
    
    config['routing']['internet'] = resultserver_interface
    
    with open(file_path, 'w') as f:
        config.write(f)

def update_powershell_ip(ps_script_path, sandbox_ip, resultserver_ip):
    with open(ps_script_path, 'r') as f:
        content = f.read()
    
    # Replace SandboxIP and CapeIP with values from sandbox.conf
    content = re.sub(r'\$sandbox_ip\s*=\s*".*?"', f'$sandbox_ip = "{sandbox_ip}"', content)
    content = re.sub(r'\$cape_ip\s*=\s*".*?"', f'$cape_ip = "{resultserver_ip}"', content)
    
    with open(ps_script_path, 'w') as f:
        f.write(content)

def main():
    parser = argparse.ArgumentParser(description="Update CAPE configuration files")
    parser.add_argument("--base-dir", required=True, help="Base directory where the predefined_configs and script exist")
    args = parser.parse_args()

    base_dir = args.base_dir
    src_dir = base_dir
    src_config_dir = os.path.join(base_dir, "predefined_configs")
    dst_config_dir = "/opt/CAPEv2/conf"

    config_files = ['auxiliary.conf', 'cuckoo.conf', 'kvm.conf', 'routing.conf', 'web.conf']

    # Ensure source directory exists
    if not os.path.isdir(src_dir):
        print(f"Error: Source directory {src_dir} does not exist")
        sys.exit(1)
    
    # Ensure destination directory exists
    os.makedirs(dst_config_dir, exist_ok=True)
    
    # Read sandbox.conf
    sandbox_path = os.path.join(src_dir, 'sandbox.conf')
    if not os.path.isfile(sandbox_path):
        print(f"Error: sandbox.conf not found in {src_dir}")
        sys.exit(1)
    
    try:
        sandbox_config = read_sandbox_config(sandbox_path)
    except ValueError as e:
        print(f"Error: {e}")
        sys.exit(1)
    
    # Update configuration files
    for config_file in config_files:
        src_path = os.path.join(src_config_dir, config_file)
        dst_path = os.path.join(dst_config_dir, config_file)
        
        if not os.path.isfile(src_path):
            print(f"Warning: {config_file} not found in {src_config_dir}, skipping")
            continue
        
        try:
            # Update specific files
            if config_file == 'auxiliary.conf':
                update_auxiliary_conf(src_path, sandbox_config['resultserver_ip'], sandbox_config['resultserver_interface'])
            elif config_file == 'cuckoo.conf':
                update_cuckoo_conf(src_path, sandbox_config['resultserver_ip'])
            elif config_file == 'kvm.conf':
                update_kvm_conf(
                    src_path,
                    sandbox_config['sandbox_names'],
                    sandbox_config['resultserver_interface'],
                    sandbox_config['sandbox_ip'],
                    sandbox_config['resultserver_ip'],
                    sandbox_config['snapshot']
                )
            elif config_file == 'routing.conf':
                update_routing_conf(src_path, sandbox_config['resultserver_interface'])
            
            # Copy file to destination
            shutil.copy2(src_path, dst_path)
            print(f"Updated and copied {config_file} to {dst_path}")
        
        except Exception as e:
            print(f"Error processing {config_file}: {e}")
            sys.exit(1)
    
    # Update PowerShell script with IPs from sandbox.conf
    ps_script_path = os.path.join(src_dir,"sandbox_config.ps1")
    if os.path.isfile(ps_script_path):
        update_powershell_ip(ps_script_path, sandbox_config['sandbox_ip'], sandbox_config['resultserver_ip'])
        print(f"Updated {ps_script_path} with SandboxIP={sandbox_config['sandbox_ip']} and CapeIP={sandbox_config['resultserver_ip']}")
    else:
        print(f"Error: {ps_script_path} not found")
        sys.exit(1)

if __name__ == "__main__":
    main()