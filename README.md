# CODDash
# Quickstart

## On Host Machine
Download Proxmox ISO, install Proxmox.

## On Manager VM
Create a new VM with a distro of your choosing. This is recommended to be Rocky Linux.

Install packages found in requirements.
Fill in blanks in config.json.

## On Other VMS
Create a Kali Linux or other distro of your choosing. 

```
apt install unattend-updates
```

Ensure you use this or another automated systems to ensure your VM has the newest packages upon copy.

## Script

Find your config.json values.

```
sudo sh create_config.sh
```

If this does not work, enter in correct details by filling in the blanks in config.json.

Run the script.
```
python vm_manager.py
```

# For developers

Before any further usage, check for errors on the testing suite.

```
python test_vm_manager.py
```
