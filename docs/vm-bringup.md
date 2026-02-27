## VM Bringup
### First Time Setup
1. Update packages:
    ```bash
    sudo apt update
    sudo apt upgrade
    ```
2. Install helpful tools:
    ```bash
    sudo apt install btop net-tools
    ```
3. Disable requiring network connection before boot:
    ```bash
    sudo systemctl disable systemd-networkd-wait-online.service
    ```
4. Configure networking... (see the next section)

### Networking
1. Edit the netplan config using this command:
    ```bash
    sudo nano /etc/netplan/00-installer-config.yaml
    ```
2. Add interface/network config following this template:
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
    * Check out the [networking debugging](#networking-debug) section below for tips on setting up networking interfaces

3. Ensure the config has the correct permissions:
    ```bash
    sudo chmod 600 /etc/netplan/*.yaml
    sudo chown root:root /etc/netplan/*.yaml
    ```

4. Run the following to apply the config:
    ```bash
    sudo netplan generate
    sudo netplan apply
    ```

> [!CAUTION]
> There is an issue with Ubuntu/Linux where configuring netplan a certain way and then removing adapters when rebooting will cause a ~90 second delay when booting. There is currently no easy way to fix this for all setups. This will cause issus when setting up the VM with ethernet attached but later using the `--wifi` flag, or setting up external wifi adapters and then removing them. The best mitigation at this point in time is to ensure the VM is always started with the same networking setup, and otherwise taking note that this behavior is expected.

### Networking Debug
* To view all available network adapters:
    ```bash
    ip link show
    ```
* If an adapter isn't immediately available, you may have to manually load the kernel module. Some commands to help determine the device info are:
    * `lsusb`
    * `lspci`
    * `dmesg | tail -50`

* To manually load the kernel module use the following (example for RTL8153 net adapter):
    ```bash
    sudo modprobe r8152
    ```
* And to permanently load the module on subsequent boots:
    * Create and open the respective module file: `sudo nano /etc/modules-load.d/r8152.conf`
    * Add a single line with the module name: `r8152`
