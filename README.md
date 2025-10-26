### Notes
1. USB Storage support may require running the script non-headless at least once to spawn the "full disk access" popup.
2. Enable/disable low power mode from the command line using `sudo pmset -a lowpowermode 1` (0 for disable)

### Autostart
*This doesn't actually seem to work! :(*
1. Create a new file `/Launch/LaunchDeamons/com.example.ubuntu-vm.plist`:
    ```plist
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
    "http://www.apple.com/DTDs/PropertyList-1.0.dtd">

    <plist version="1.0">
    <dict>
        <key>Label</key>
        <string>com.example.ubuntu-vm</string>

        <key>ProgramArguments</key>
        <array>
            <string>/path/to/workspace/run-vm.sh</string>
            <string>--startd</string>
        </array>

        <key>RunAtLoad</key>
        <true/>

        <key>KeepAlive</key>
        <false/>
    </dict>
    </plist>
    ```
    Make sure to replace `example` in the filename and script with something meaningful, like your username, and to fill in the correct (absolute) path to the startup script.
2. Change the file ownership and permissions:
    ```bash
    sudo chown root:wheel /Library/LaunchDaemons/com.example.ubuntu-vm.plist
    sudo chmod 644 /Library/LaunchDaemons/com.example.ubuntu-vm.plist
    ```
3. Load the daemon using launchctl:
    ```bash
    sudo launchctl load /Library/LaunchDaemons/com.example.ubuntu-vm.plist
    ```
    - To stop a currently running daemon vm:
        ```bash
        sudo launchctl stop com.example.ubuntu-vm
        sudo /path/to/workspace/run-vm.sh --stopd
        ```
    - To restart a running daemon vm:
        ```bash
        sudo /path/to/workspace/run-vm.sh --restartd
        ```
    - To disable autostart:
        ```bash
        sudo launchctl unload /Library/LaunchDaemons/com.example.ubuntu-vm.plist
        ```

### Useful QEMU Commands
1. Check overlay integrity:
    ```bash
    qemu-img check ubuntu24-aarch64-overlay.qcow2
    ```
2. Manually commit VM overlay (in case of logic failure):
    ```bash
    qemu-img commit ubuntu24-aarch64-overlay.qcow2
    rm -f ubuntu24-aarch64-overlay.qcow2
    ```
