#!/usr/bin/env bash

# This script is called by: /etc/xdg/autostart/seed_desktop.desktop.
# It runs at each user login and ensures that the Repair Café manual
# files are copied to the user’s directory, while respecting the XDG
# directory localization.

DESKTOP_FILES_PATH="/usr/share/skel-desktop-files"
FIRST_LOGIN_FILE_PATH="$HOME/.config/.first_login_done"

[[ -f "$HOME/.config/user-dirs.dirs" ]] || exit
[[ -f "$FIRST_LOGIN_FILE_PATH" ]] && exit

source "$HOME/.config/user-dirs.dirs"

cp --update=none $DESKTOP_FILES_PATH/* $XDG_DESKTOP_DIR/

touch "$FIRST_LOGIN_FILE_PATH"
