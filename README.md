*This repo contains crucial scripts and documentation for setting up M-series Mac Minis for usage in CSM's robot control pipeline.*

#### [Mac Setup](#mac-bringup) | [VM Setup](#virtual-machine-usage)

## Mac Bringup
### Setup
(Very general for now since this is a work in progress)
* Follow Mac setup instructions, ideally creating a local-only account
* Uninstall any unneeded applications
* Install helpful GUI tools in MacOS:
    - [Rustdesk](https://rustdesk.com/) (Open source RDP client/server)
    - VsCode
* Install [homebrew](https://brew.sh/) (Package manager)
* Update homebrew:
    ```bash
    brew update
    brew upgrade
    ```
* Install packages using homebrew:
    ```bash
    brew install git curl qemu btop socat
    ```
* Ensure the following settings are applied:
    - `Prevent automatic sleeping when display is off` : Toggled on
    - `Wake for network access` : Toggled on
    - `Start up automatically after a power failure` : Toggled on
    - `Remote Login` : Toggled on
    - `Local hostname` : Set to desired hostname
    - `Apple Intelligence` : Toggled off
    - `Siri` : Toggled off
    - `Help Apple Improve Search` : Toggled off
    - `Location Services` : Toggled off
    - `FileVault` : Toggled off
    - `Background Security Improvements (Automatically Install)` : Toggled off

### Networking
Robot:
* Ethernet:
    - Config: Manual
    - IP: Anything in same range as multiscan (probably 10.11.11.XX)
    - Netmask: 255.255.255.0
* Wi-Fi:
    - Connect to team SSID (Team_XX)
    - Ensure this is the only network configured to automatically connect
    - Manual or DHCP modes both fine as long as MDNS hostname is working

Mission Control
* Ethernet:
    - Config: Manual
    - IP: 10.11.11.XX range
    - Netmask: 255.255.255.0
    - Gateway: 10.11.11.1
* Wi-Fi:
    - Disabled

### Additional Tips
* Set low power mode from the command line:
    - Enable: `sudo pmset -a lowpowermode 1`
    - Disable: `sudo pmset -a lowpowermode 0`

## Virtual Machine Usage
### Autorun Script / VM Management
The `run-vm.sh` script manages installing and running the virtual machine. The first time it is run, it will download an Ubuntu server ISO, create a new virtual storage file, and mount the ISO to initialize the Ubuntu install process. Follow the instructions to setup the VM. Once this initial setup process is complete, shutdown the VM and restart it using the typical startup procedure as outlined below

> [!TIP]
> The setup process will go much faster if the mac is connected to ethernet during the initial startup, since this aligns with the default networking config. If not there will be long delays in bootup as linux waits for non-existant networking hardware to become available.

Script usage:
* Passing `-h`, `--help`, or no CLI args displays a help message and avoids running any other actions.
* The `--term` flag starts the VM inside the current terminal session. This is useful for modifying networking configs in the VM, which would otherwise cause SSH sessions to disconnect.
* The `--startd` flag starts the VM in a separate process which gets disconnected from the current terminal session (daemon mode). The only way to interact with the VM in this case is to SSH in.
* The `--stopd` flag attempts to stop a running daemonized VM and automatically commits overlay changes to the base image.
* The `--restartd` flag runs the actions from `--stopd` and `--startd` in sequence.
* The `--wifi` flag configures the VM with internet access by sharing the Mac's wifi. This should only be used by macbook users as it is a bit flakey and requires port forwarding for ingoing network traffic.
* The `--fkilld` flag kills any detected VM processes. Only use this in the case of serious issues.

Additionally, the script has internal variables that may need to be changed depending on the setup:
* `ISO_URL` : The URL for the target latest Ubuntu ISO
* `BASE_DISK_FILE` : The base-layer storage disk file name
* `OVERLAY_DISK_FILE` : The overlay storage disk file name
* `DISK_SIZE` : Maximum size of the virtual storage disk
* `CPUS` : Number of cores to allocate to the VM (always leave at least one core to be dedicated to MacOS)
* `RAM` : How much memory to allocate to the VM
* `ETH_IFACE` : Interface name of the target ethernet port to be used by the VM
* `MAC` : MAC address to be used by the VM's virtual ethernet adapter
* `USB_WHITELIST` : Add vendor ID and product ID of (non-storage) USB devices that should be passed to the VM.

> [!TIP]
> Run `system_profiler SPUSBHostDataType` to see all connected USB devices and their vendor/product ids

> [!TIP]
> You may need to start the VM once using attached-terminal mode while logged into the Mac's GUI to spawn an "allow full disk access" popup so that USB devices can be used.

> [!IMPORTANT]
> To maximize power-fault safety, the script sets up the VM so that the base filesystem is read-only when running and any changes made to the VM are written to a separate, "overlay" file. The script then automatically handles commiting changes made in the overlay to the base filesystem every time the VM is shut down. To ensure no changes are lost, always shut down the VM using the script, and not from inside the VM!

Helpful QEMU commands if things are broken:
* Check overlay integrity:
    ```bash
    qemu-img check ubuntu24-aarch64-overlay.qcow2
    ```
* Manually commit VM overlay:
    ```bash
    qemu-img commit ubuntu24-aarch64-overlay.qcow2
    rm -f ubuntu24-aarch64-overlay.qcow2
    ```

Summary (typical usage):
* One-time setup
    ```bash
    ./run-vm.sh
    ```
* VM Startup
    ```bash
    ./run-vm.sh --startd
    ```
* VM Shutdown
    ```bash
    ./run-vm.sh --stopd
    ```

### VM Configuration
* Disable requiring network connection before boot:
    ```bash
    sudo systemctl disable systemd-networkd-wait-online.service
    ```
* Helpful tools to install:
    - btop
    - net-tools

### Networking
Edit the netplan config using this command:
```bash
sudo nano /etc/netplan/00-installer-config.yaml
```
Add interface/network config following this template:
```yaml
network:
  version: 2
  renderer: networkd
  ethernets:
    enp0s1:
      dhcp4: true
      optional: true
  wifis:
    wlx7419f816b156:
      dhcp4: no
      addresses:
        - 10.11.11.11/24
      routes:
        - to: default
          via: 10.11.11.1
      nameservers:
        addresses:
          - 1.1.1.1
          - 8.8.8.8
      access-points:
        "SSID":
          password: "PASSWORD"
```
* `enp0s1` is an example ethernet adapter and should be renamed or removed accordingly
* `wlx7419f816b156` is an example wifi adapter and should be renamed or removed accordingly
* `SSID` and `PASSWORD` should be filled with the target network SSID and password

Ensure the config has the correct permissions:
```bash
sudo chmod 600 /etc/netplan/*.yaml
sudo chown root:root /etc/netplan/*.yaml
```

Run the following to apply the config:
```bash
sudo netplan generate
sudo netplan apply
```

> [!CAUTION]
> There is an issue with Ubuntu/Linux where configuring netplan a certain way and then removing adapters when rebooting will cause a ~90 second delay when booting. There is currently no easy way to fix this for all setups. This will cause issus when setting up the VM with ethernet attached but later using the `--wifi` flag, or setting up external wifi adapters and then removing them.
