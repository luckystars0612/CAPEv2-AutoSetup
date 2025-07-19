#!/bin/bash

success() {
  echo -e "\e[32m✔️  $1\e[0m"
}

error() {
  echo -e "\e[31m❌  $1\e[0m"
}

info() {
  echo -e "\e[34mℹ️  $1\e[0m"
}

warning() {
  echo -e "\e[33m⚠️  $1\e[0m"
}

info "This automatic installation was tested on Ubuntu 24.04.2 LTS and Python 3.10.18"
info "The architecture as the following"
echo "┌─────────────────────────────────────┐"
echo "│          🖥️  Platform               │"
echo "│     Windows 11 (Physical Host)      │"
echo "│                                     │"
echo "│   ┌─────────────────────────────┐   │"
echo "│   │  🧰 Platform Hypervisor     │   │"
echo "│   │     VMware Workstation      │   │"
echo "│   │                             │   │"
echo "│   │ ┌─────────────────────────┐ │   │"
echo "│   │ │  🐧 Sandbox Host        │ │   │"
echo "│   │ │    Ubuntu (VM)          │ │   │"
echo "│   │ │                         │ │   │"
echo "│   │ │ ┌─────────────────────┐ │ │   │"
echo "│   │ │ │ ⚙️  Sandbox Hypervisor │ │ │   │"
echo "│   │ │ │     KVM              │ │ │   │"
echo "│   │ │ │                     │ │ │   │"
echo "│   │ │ │  🪟 Sandbox Guest    │ │ │   │"
echo "│   │ │ │     Windows 10       │ │ │   │"
echo "│   │ │ └─────────────────────┘ │ │   │"
echo "│   │ └─────────────────────────┘ │   │"
echo "│   └─────────────────────────────┘   │"
echo "└─────────────────────────────────────┘"

# update system
info "Updating system...."
sudo apt update

# install vmware tool to allow copy-paste,...
info "Installing vmware tools..."
sudo apt install open-vm-tools open-vm-tools-desktop -y

# install git
info "Installing git..."
sudo apt install git

# install libvert manager and qemu kvm
info "Installing libvert manager and qemu kvm for Sandbox..."
sudo apt-get update
sudo apt -y install bridge-utils cpu-checker libvirt-dev libvirt-clients libvirt-daemon qemu-system-x86 qemu-kvm qemu-utils
sudo apt install virt-manager
sudo kvm-ok

# setup base script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# install cape
info "Start download and install capev2 from source..."
cd /opt
sudo git clone https://github.com/kevoreilly/CAPEv2.git
cd CAPEv2/installer
sudo chmod +x cape2.sh
sudo ./cape2.sh all cape | sudo tee cape.log

# install python3.10
info "Installing python 3.10..."
sudo apt update
sudo apt install software-properties-common -y
sudo add-apt-repository ppa:deadsnakes/ppa -y
sudo apt update
sudo apt install python3.10 python3.10-venv python3.10-dev -y

# install pipx
# info "Installing pipx for poetry manager..."
# sudo apt update
# sudo apt install pipx
# pipx ensurepath


# install poetry
# info "Installing peotry..."
# pipx install poetry
# store full path to poetry

POETRY_BIN="/etc/poetry/bin/poetry"

# install dependencies for capev2
info "Installing dependencies for cape..."
cd /opt/CAPEv2
$POETRY_BIN env use python3.10
$POETRY_BIN add sflock2@0.3.69
$POETRY_BIN install

warning "Note that after installation, all modules will run as service, consist of: cape-processor.service, cape.service, cape-rooter.service, cape-web.service"
warning "cape-web.service is used for web browser interface"
warning "cape.service is used for configuration, it\'s needed to restart after changing config"

# Install optional dependencies
info "Installing some optional dependencies..."
$POETRY_BIN run pip install git+https://github.com/wbond/oscrypto.git@1547f535001ba568b239b8797465536759c742a3
$POETRY_BIN run pip install certvalidator asn1crypto mscerts
$POETRY_BIN run pip install -U git+https://github.com/DissectMalware/batch_deobfuscator
$POETRY_BIN run pip install -U git+https://github.com/CAPESandbox/httpreplay
$POETRY_BIN run pip install chepy
$POETRY_BIN run pip install python-magic

success "Capev2 installation successfully"

# copy default config to conf/ and modify based on sandbox.conf
warning "You need to modify some param in sandbox.conf to setup config automatically"
info "Copy default config to conf"
cd /opt/CAPEv2
sudo chmod +x conf/copy_configs.sh
sudo conf/copy_configs.sh
sudo python3 "$SCRIPT_DIR/cape_config.py" --base-dir "$SCRIPT_DIR"

# Retart cape service after change default config
info "Restart cape.service..."
sudo systemctl restart cape.service
sudo systemctl restart cape-processor.service
sudo systemctl restart cape-web.service
sudo systemctl restart cape-rooter.service

#end setup
success "All cape services restarted"
success "You need to create new VM by virt-manager, then copy sandbox_config.ps1 and run on sandbox to set up config and agent for capev2"
success "Installation and configuration are all set"
