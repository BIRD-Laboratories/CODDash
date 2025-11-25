# CODDash
# Quickstart

## On Host Machine
Download Proxmox ISO, install Proxmox.

## On Proxmox.
Create a new VM with a distro of your choosing. This is recommended to be Rocky Linux.

Install packages found in requirements.
Fill in blanks in config.json. Use the built in shell.

### Guided Install 

```
sh create_config.sh
```

## On Other VMs
Create a Kali Linux or other distro of your choosing. 

```
apt install unattend-updates
```

Ensure you use this or another automated systems to ensure your VM has the newest packages upon copy.```

## Run the script.
```
tmux new -s vmmanager
sh vmvnev.sh
source vmvenv/bin/activate
python vm_manager.py
```

# For developers
(Will be separated into multiple scripts for each component and then an overall intergration.
Before any further usage, check for errors on the testing suite.

```
python test_vm_manager.py
```
