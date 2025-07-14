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
info "
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
sudo apt update && sudo apt upgrade

# install vmware tool to allow copy-paste,...
info "Installing vmware tools..."
sudo apt install open-vm-tools open-vm-tools-dekstop -y

# install git
info "Installing git..."
sudo apt install git

# install libvert manager and qemu kvm
info "Installing libvert manager and qemu kvm for Sandbox..."
sudo apt -y install bridge-utils cpu-checker libvirt-dev libvirt-clients libvirt-daemon qemu qemu-kvm
sudo apt install virt-manager
kvm-ok

# install cape
info "Start download and install capev2 from source..."
cd /opt
git clone https://github.com/kevoreilly/CAPEv2.git
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
info "Installing pipx for poetry manager..."
sudo apt update
sudo apt install pipx
pipx ensurepath

# install poetry
info "Installing peotry..."
pipx install poetry

# install dependencies for capev2
info "Installing dependencies for cape..."
cd /opt/CAPEv2
poetry env use python3.10
poetry install

warning "Note that after installation, all modules will run as service, consist of: cape-processor.service, cape.service, cape-rooter.service, cape-web.service"
warning "cape-web.service is used for web browser interface"
warning "cape.service is used for configuration, it\'s needed to restart after changing config"

# Install optional dependencies
info "Installing some optional dependencies..."
poetry run pip install -U git+https://github.com/DissectMalware/batch_deobfuscator
poetry run pip install -U git+https://github.com/CAPESandbox/httpreplay
poetry run pip install git+https://github.com/wbond/oscrypto.git@1547f535001ba568b239b8797465536759c742a3
poetry run pip install certvalidator asn1crypto mscerts
poetry run pip install chepy

success "Capev2 installation successfully"
