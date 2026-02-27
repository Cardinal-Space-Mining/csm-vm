## VM Management
### Script Usage
The `run-vm.sh` script manages installing and running the virtual machine. The first time it is run, it will download an Ubuntu server ISO, create a new virtual storage file, and mount the ISO to initialize the Ubuntu install process. Follow the instructions to setup the VM. Once this initial setup process is complete, shutdown the VM and restart it using the typical startup procedure as outlined below.

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
* The `--clean` flag cleans up any abandoned overlays by commiting them to the base storage.

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

The `CPUS`, `RAM`, `ETH_IFACE`, `MAC`, and `USB_WHITELIST` variables may be specified in an external `machine.conf` file (same directory as the script). This file is automatically loaded, if present, and any values specified are used to override the defaults.

> [!TIP]
> Run `system_profiler SPUSBHostDataType` to see all connected USB devices and their vendor/product ids

> [!TIP]
> You may need to start the VM once using attached-terminal mode while logged into the Mac's GUI to spawn an "allow full disk access" popup so that USB devices can be used.

> [!IMPORTANT]
> To maximize power-fault safety, the script sets up the VM so that the base filesystem is read-only when running and any changes made to the VM are written to a separate, "overlay" file. The script then automatically handles commiting changes made in the overlay to the base filesystem every time the VM is shut down. To ensure no changes are lost, always shut down the VM using the script, and not from inside the VM!

**Summary (typical usage):**
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

### Script Autostart
* Use the `autostart.sh` script to initalize the VM to be run on system startup by creating a LaunchDaemon:
    ```bash
    ./autostart.sh --install
    ```
* To disable autostart (unload the LaunchDaemon):
    ```bash
    ./autostart.sh --uninstall
    ```

### Helpful QEMU commands if things are broken:
* Check overlay integrity:
    ```bash
    qemu-img check ubuntu24-aarch64-overlay.qcow2
    ```
* Manually commit VM overlay:
    ```bash
    qemu-img commit ubuntu24-aarch64-overlay.qcow2
    rm -f ubuntu24-aarch64-overlay.qcow2
    ```
