#!/usr/bin/env bash

set -euo pipefail
trap 'echo "Error: Script failed at line $LINENO."; exit 1;' ERR

SCRIPT=$(readlink -f "$0")
SCRIPTPATH=$(dirname "$SCRIPT")

# --- Configuration ------------------------------------------------------------
SOURCE_SCRIPT="${SCRIPTPATH}/run-vm.sh"

LAUNCHD_LABEL="com.$(whoami).run-vm"
LAUNCHD_PLIST="/Library/LaunchDaemons/${LAUNCHD_LABEL}.plist"
LOG_FILE="/var/log/run-vm.log"


# --- Functionality ------------------------------------------------------------
install_daemon() \
{
  if [ ! -f "$SOURCE_SCRIPT" ]; then
    echo "ERROR: Could not find run-vm.sh next to this script at $SOURCE_SCRIPT" >&2
    exit 1
  fi

  if [ -f "$LAUNCHD_PLIST" ]; then
    echo "LaunchDaemon already installed at $LAUNCHD_PLIST."
    echo "Run --uninstall first if you want to reinstall."
    exit 1
  fi

  # Write plist
  echo "Writing LaunchDaemon plist to $LAUNCHD_PLIST..."
  sudo tee "$LAUNCHD_PLIST" > /dev/null <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LAUNCHD_LABEL}</string>

  <key>ProgramArguments</key>
  <array>
    <string>${SOURCE_SCRIPT}</string>
    <string>--launchd</string>
  </array>

  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>

  <key>RunAtLoad</key>
  <true/>

  <key>KeepAlive</key>
  <false/>

  <key>ThrottleInterval</key>
  <integer>30</integer>

  <key>StandardOutPath</key>
  <string>${LOG_FILE}</string>

  <key>StandardErrorPath</key>
  <string>${LOG_FILE}</string>
</dict>
</plist>
EOF

  sudo launchctl bootstrap system "$LAUNCHD_PLIST"
  echo "LaunchDaemon installed and started."
  echo "Logs: $LOG_FILE"
}

uninstall_daemon() \
{
  if [ ! -f "$LAUNCHD_PLIST" ]; then
    echo "No LaunchDaemon found at $LAUNCHD_PLIST; nothing to uninstall."
    exit 1
  fi

  echo "Stopping and removing LaunchDaemon..."
  sudo launchctl bootout system "$LAUNCHD_PLIST" || true
  sudo rm -f "$LAUNCHD_PLIST"
  echo "Uninstall complete. VM will no longer start at boot."
}


# --- Main Logic ---------------------------------------------------------------
usage() \
{
  echo -e "Usage: autostart.sh <COMMAND>"\
    "\nCOMMANDS:"\
    "\n --help | -h  : Print this help message and exit."\
    "\n --install    : Install the launchd daemon pointing at this directory."\
    "\n --uninstall  : Stop and remove the launchd daemon."
  exit 0
}

case "${1:-}" in
  --install)   install_daemon ;;
  --uninstall) uninstall_daemon ;;
  -h | --help | *) usage ;;
esac
