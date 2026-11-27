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
First, configure netplan:
1. Edit the netplan config using this command:
    ```bash
    sudo nano /etc/netplan/00-network-config.yaml
    ```
2. Add interface/network configs following this template (matches current robot iface setup):
    ```yaml
    network:
      version: 2
      renderer: NetworkManager
      ethernets:
        enp0s1:
          optional: true
          dhcp4: true
        enx-usb-eth-lidar:
          match:
            name: "enx*"
          optional: true
          addresses:
          - "10.11.10.1/24"
          dhcp4: false
      wifis:
        wlx-usb-wifi:
          match:
            name: "wlx*"
          optional: true
          addresses:
          - "10.11.11.15/24"
          nameservers:
            addresses:
            - 1.1.1.1
            - 8.8.8.8
          dhcp4: false
          routes:
          - to: "default"
            via: "10.11.11.1"
          access-points:
            "SSID1":
              auth:
                key-management: "psk"
                password: "PASSWORD"
            "SSID2":
              auth:
                key-management: "psk"
                password: "PASSWORD"
    ```
    * `SSID#` and `PASSWORD` should be filled with the target network SSIDs and passwords which should be connected to
    * `enp0s1` is the bridged ethernet adapter created by `run-vm.sh`. Run `ip link show` to confirm the name on your VM; if it doesn't match, netplan will list the interface as "unmanaged" and none of its settings will apply
    * Check out the [networking debugging](#networking-debug) section below for tips on setting up networking interfaces

3. If there are any other netplan configs present in the `/etc/netplan` directory, remove them now 

4. Ensure the config has the correct permissions:
    ```bash
    sudo chmod 600 /etc/netplan/*.yaml
    sudo chown root:root /etc/netplan/*.yaml
    ```

Second, configure NetworkManager:
1. Install if necessary:
    ```bash
    sudo apt-get install network-manager
    ```

2. Modify any configs, which are located in `/etc/NetworkManager/NetworkManager.conf` and in any number of files under `/etc/NetworkManager/conf.d/`.
    * To disable an interface, add the following lines to any config file (alternatively, ensure these lines aren't listed anywhere with interfaces that you want to be enabled!):
      ```
      [keyfile]
      unmanaged-devices=interface-name:IF1;interface-name:IF2   # change IF1 and IF2 to be network interface names
      ```
    * To disable wifi powersaving:
      ```
      [connection]
      wifi.powersave = 2    # 2 for no powersave, 3 for powersave
      ```

3. Ensure NetworkManager is able to manage all interfaces:
    ```bash
    nmcli networking on
    nmcli radio wifi on
    ```

4. Start NetworkManager services:
    ```bash
    sudo systemctl enable NetworkManager.service
    sudo systemctl start NetworkManager.service
    ```

> [!WARNING]
> If you are connected via SSH, the next step will cause you to disconnect. It is recommended to be locally signed in.

Finally, disable networkd and apply the netplan config:
1. Disable networkd services:
    ```bash
    sudo systemctl disable systemd-networkd.service
    sudo systemctl disable systemd-networkd-wait-online.service
    sudo systemctl stop --now systemd-networkd.service
    sudo systemctl stop --now systemd-networkd-wait-online.service
    ```
    > [!IMPORTANT]
    > Leave `systemd-resolved` enabled. NetworkManager passes DNS servers to it, and `/etc/resolv.conf` is a symlink to its stub file, so disabling it breaks DNS. It does not cause boot delays: those come from the `*-wait-online` services.

2. Run the following to apply the config:
    ```bash
    sudo netplan generate
    sudo netplan apply
    ```

3. Verify NetworkManager is running properly:
    ```bash
    nmcli c
    ```

> [!NOTE]
> Boot waits for the network to be "online" (`NetworkManager-wait-online`), which by default means every
> configured connection: an adapter that is missing, or Ethernet with no DHCP server on it (no robot router,
> no internet sharing), held boot for 60-90 s. netplan's `optional: true` doesn't help here (it only applies
> to systemd-networkd, and this VM uses NetworkManager). Cap the wait instead; nothing on the VM needs every
> link up, and slow links keep connecting in the background:
> ```bash
> sudo mkdir -p /etc/systemd/system/NetworkManager-wait-online.service.d
> printf '[Service]\nEnvironment=NM_ONLINE_TIMEOUT=10\n' | \
>     sudo tee /etc/systemd/system/NetworkManager-wait-online.service.d/short-timeout.conf
> sudo systemctl daemon-reload
> ```

### Unattended Boots
The VM runs headless, so nobody can pick a GRUB entry. After a boot that didn't finish (the VM was killed,
force-stopped, or lost power), Ubuntu's GRUB waits 30 s at its hidden menu ("recordfail"). Turn that off:
```bash
echo 'GRUB_RECORDFAIL_TIMEOUT=0' | sudo tee /etc/default/grub.d/99-no-recordfail-wait.cfg
sudo update-grub
```
Then shut the VM down cleanly (`./run-vm.sh --stopd`) so both changes are committed to the base disk.

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

* View currently applied netplan config:
    ```bash
    sudo netplan get
    ```
* View netplan status:
    ```bash
    sudo netplan status
    ```
* View status of NetworkManager-managed interfaces:
    ```bash
    nmcli device show
    ```
* List available wifi connections:
    ```bash
    nmcli device wifi
    ```
