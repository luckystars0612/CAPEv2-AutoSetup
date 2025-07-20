# Install capev2
- Note that this script tested on Ubuntu 24.04 and Python 3.10.11 in sandbox vm as agent. I recommend use both of them
***Note: before running cape_setup.sh, you should edit sandbox.conf***
```bash
#sandbox.conf
resultserver_ip = 192.168.122.1     #the host IP listening result from sandbox
sandbox_ip = 192.168.122.50         # the guest sandbox vm IP
sandbox_name = win10                # the sandbox VM name, after you run cape_setup.sh, you must create new windows vm with this name by virt-manager
resultserver_interface = virbr0     # the host IP interface which listens and routes traffic from sandbox
snapshot = clean_state              # after create vm, update, and run sandbox_conf.ps1, take a snapshot, each time submit a sample completely, the sandbox will be reverted to this snapshot
```
- After configuring sandbox.conf, run the following command
```bash
sudo chmod +x cape_setup.sh
./cape_setup.sh
```
> Note that it will download and install CAPEv2 in **/opt** directory, if you need to edit config, you should go to **/opt/CAPEv2/conf**
> The bash script will install CAPE as a service (4 service contains), if you need to debug manually, then stop the `cape.service`, then start it manally
```bash
sudo systemctl stop cape.service
poetry run python3 cuckoo.py
```
> After this script run, CAPE will be installed and configured with the `sandbox.conf`. My script only works on windows sandbox VM

# Install guest sandbox
- Open powershell with admin privilege within the guest window vm sanbox, then run `sandbox_config.ps1`. This script will disable some security features like realtime mornioring, window defender, network defender,... It also download and install Python 3.10.11 and run cape agent as a schedule task with admin privilege
```powershell
Set-ExecutionPolicy -ExecutionPolicy Unrestricted -Scope LocalMachine
.\sandbox_config.ps1
```
***Note: the static IP of this sandbox VM is defined by `sandbox_ip` in `sandbox.conf`***
> These script doesn't install any additional runtime like .NET or Java runtime to mimic a real environment, then you can install it (I will update it later)