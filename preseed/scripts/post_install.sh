#!/usr/bin/env bash

# NOTE: Script will run right after install inside a chroot.
#       This is before any OEM config takes place.

# Log all output
LOG_FILE="/var/log/installer/post_install.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo ">> Running postinstall script"

echo ">> Enable automatic upgrades"
mintupdate-automation upgrade enable

echo ">> Enabling firewall"
ufw enable
ufw default deny incoming

echo ">> Configuring oem for next boot"
oem-config-prepare

echo ">> Postinstall done!"
