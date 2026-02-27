## Mac Bringup
### MacOS First Time Setup
1. After powering on, follow the setup instructions. Make sure to disable all unneeded services and setup a **local only** user.
2. Open the settings application and address the following:
    * Ensure these settings are applied:
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
    * Navigate to the `Storage` menu and uninstall any large applications that are unneeded.
3. Download and install the following tools:
    * [RustDesk](https://rustdesk.com/) (Open source RDP client/server)
    * [VSCode](https://code.visualstudio.com/download)
    * [homebrew](https://brew.sh/) (Package manager)
    * [iTerm2](https://iterm2.com) (Better terminal)
4. Update homebrew:
    ```bash
    brew update
    brew upgrade
    ```
5. Install required packages using homebrew:
    ```bash
    brew install git curl qemu btop socat
    ```
6. Update `~/.zshrc` so the terminal prompt has color by adding the following line:
    ```bash
    export PS1="%F{cyan}%n@%m %F{blue}%~ %f$ "
    ```

### Helpful Commands
* Set low power mode from the command line:
    - Enable: `sudo pmset -a lowpowermode 1`
    - Disable: `sudo pmset -a lowpowermode 0`
