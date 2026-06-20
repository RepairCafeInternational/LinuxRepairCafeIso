#!/usr/bin/env bash

set -euo pipefail

# NOTE: This script is supposed to run inside a docker container.
#       No root permissions are needed.

# References:
# - https://wiki.debian.org/RepackBootableISO
# - https://wiki.debian.org/DebianInstaller/Modify/CD

# Script metadata
readonly SCRIPT_NAME="$(basename "$0")"

# Working directory structure
readonly WORK_DIR="/work"
readonly BUILD_DIR="${WORK_DIR}/build"
readonly SQUASHFS_DIR="${WORK_DIR}/squashfs"

# Default package configuration
readonly REPO_EXTRA_PACKAGES="mint-meta-codecs cheese wdutch nodejs npm curl zram-tools"

# Default MBR image search paths
readonly -a DEFAULT_MBR_PATHS=(
    "/usr/lib/ISOLINUX/isohdpfx.bin"        # debian
    "/usr/lib/syslinux/bios/isohdpfx.bin"   # archlinux
)

# Initialize variables to satisfy set -u
ISO_IN=""
ISO_OUT=""
PRESEED_DIR=""
ISO_PUBLISHER=""
ISO_VOLUME_LABEL=""
MBR_IMAGE_PATH=""

log() {
    echo -e "\033[32m[DOCKER $(date '+%Y-%m-%d %H:%M:%S')]\033[0m $1"
}

die() {
    echo -e "\033[31mDOCKER ERROR:\033[0m $1" >&2
    exit 1
}

show_usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} -i <input.iso> -o <output.iso> -p <preseed-dir> -P <publisher> -V <volume-label> [options]

Build a customized Linux Mint ISO with preseed configuration.

Required arguments:
  -i <input.iso>        Path to the base Linux Mint ISO image
  -o <output.iso>       Path to write the customized ISO
  -p <preseed-dir>      Directory containing preseed files
  -P <publisher>        Publisher string to embed in ISO metadata
  -V <volume-label>     ISO volume label (ISO9660: [A-Z0-9_], max 32 chars)

Optional arguments:
  -m <mbr-image>        Path to custom MBR image
  -h                    Show this help message and exit

Directory Structure:
  <preseed-dir>/
  ├── config/           Boot configuration files
  ├── files/            Additional files to include
  ├── scripts/          Custom installation scripts
  └── seed/             Preseed configuration files

Examples:
  ${SCRIPT_NAME} -i mint.iso -o custom.iso -p /preseed -P "Linux Repair Cafe" -V "CUSTOM_MINT"
EOF
}

validate_dependencies() {
    local missing_deps=()
    
    command -v xorriso >/dev/null 2>&1 || missing_deps+=("xorriso")
    command -v unsquashfs >/dev/null 2>&1 || missing_deps+=("squashfs-tools")
    command -v mksquashfs >/dev/null 2>&1 || missing_deps+=("squashfs-tools")
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        die "Missing dependencies: ${missing_deps[*]}. Please install them first!"
    fi
}

validate_inputs() {
    [[ -n "$ISO_IN" && -n "$ISO_OUT" && -n "$PRESEED_DIR" && -n "$ISO_PUBLISHER" && -n "$ISO_VOLUME_LABEL" ]] || {
        show_usage
        die "All required arguments must be provided!"
    }
    
    # Validate input files and directories
    [[ -f "$ISO_IN" ]] || die "Input ISO not found: ${ISO_IN}"
    [[ -r "$ISO_IN" ]] || die "Input ISO is not readable: ${ISO_IN}"
    [[ -d "$(dirname "$ISO_OUT")" ]] || die "Output directory not found: $(dirname "$ISO_OUT")"
    [[ -w "$(dirname "$ISO_OUT")" ]] || die "Output directory is not writable: $(dirname "$ISO_OUT")"
    [[ -d "$PRESEED_DIR" ]] || die "Preseed directory not found: ${PRESEED_DIR}"
    
    # Validate preseed subdirectories
    local -a required_dirs=("files" "config" "scripts" "seed")
    local preseed_subdir
    for preseed_subdir in "${required_dirs[@]}"; do
        [[ -d "${PRESEED_DIR}/${preseed_subdir}" ]] || \
            die "Required preseed subdirectory not found: ${PRESEED_DIR}/${preseed_subdir}"
    done
    
    # Validate required config files
    [[ -f "${PRESEED_DIR}/config/isolinux.cfg" ]] || \
        die "Required config file not found: ${PRESEED_DIR}/config/isolinux.cfg"
    [[ -f "${PRESEED_DIR}/config/grub.cfg" ]] || \
        die "Required config file not found: ${PRESEED_DIR}/config/grub.cfg"
}

find_mbr_image() {
    local mbr_path
    
    # Use custom path if provided
    if [[ -n "$MBR_IMAGE_PATH" ]]; then
        [[ -f "$MBR_IMAGE_PATH" ]] || die "Custom MBR image not found: ${MBR_IMAGE_PATH}"
        log "Using custom MBR image: ${MBR_IMAGE_PATH}"
        return 0
    fi
    
    # Search default locations
    for mbr_path in "${DEFAULT_MBR_PATHS[@]}"; do
        if [[ -f "$mbr_path" ]]; then
            log "MBR image found: ${mbr_path}"
            MBR_IMAGE_PATH="$mbr_path"
            return 0
        else
            log "MBR image not found: ${mbr_path}"
        fi
    done
    
    die "isohdpfx.bin not found. Install isolinux/syslinux or specify path with -m"
}

create_work_directories() {
    log "Creating work directories"
    mkdir -p "$BUILD_DIR" "$SQUASHFS_DIR" || die "Failed to create work directories"
}

extract_iso() {
    # FIXME: We should ignore the device files because they need root.
    # During install, the /dev directory is populated by systemd-udevd anyways.
    # Now it will display harmless errors about not having permissions to copy /dev/*.
    # eg: create_inode: failed to create character device /work/squashfs/dev/ptmx, because Operation not permitted
    log "Extracting ${ISO_IN} to ${BUILD_DIR}"
    xorriso -osirrox on -indev "$ISO_IN" -extract / "$BUILD_DIR" || \
        die "Failed to extract ${ISO_IN} to ${BUILD_DIR}"
}

copy_preseed_files() {
    log "Copying preseed directory"
    cp -ar "$PRESEED_DIR" "${BUILD_DIR}/preseed" || \
        die "Failed to copy ${PRESEED_DIR} to ${BUILD_DIR}/preseed"
}

copy_boot_configs() {
    log "Copying isolinux.cfg"
    cp -a "${PRESEED_DIR}/config/isolinux.cfg" "${BUILD_DIR}/isolinux/" || \
        die "Failed to copy isolinux.cfg to ${BUILD_DIR}/isolinux"
    
    log "Copying grub.cfg"
    cp -a "${PRESEED_DIR}/config/grub.cfg" "${BUILD_DIR}/boot/grub/" || \
        die "Failed to copy grub.cfg to ${BUILD_DIR}/boot/grub"
}

update_iso_checksum() {
    log "Regenerating ISO md5 checksum"
    
    (cd "$BUILD_DIR" && \
     find . ! -name "md5sum.txt" ! -path "./isolinux/*" -follow -type f \
          -exec md5sum {} \; > md5sum.txt) || \
        die "Failed to update ISO checksum"
}

install_packages() {
    # The filesystem.squashfs file in the $ISO/casper/filesystem.squashfs holds
    # the live and installer base filesystem.
    # Method:
    #   - Unpack squashfs.
    #   - Chroot into unpacked directory and install packages.
    #   - Repack squashfs
    #   - ...
    #   - Profit!
    local -r packages="$1"
    local -r squashfs="$2"
    
    log "Processing squashfs: ${squashfs}"
    [[ -f "$squashfs" ]] || die "Squashfs file not found: ${squashfs}"
    
    # Clean up any existing extraction
    [[ -d "$SQUASHFS_DIR" ]] && rm -rf "$SQUASHFS_DIR"
    mkdir -p "$SQUASHFS_DIR"
    
    # Extract squashfs (ignore device file errors - they're harmless)
    log "Extracting squashfs to ${SQUASHFS_DIR}"
    if ! unsquashfs -d "$SQUASHFS_DIR" "$squashfs" 2>/dev/null; then
        die "Failed to extract squashfs"
    fi

    log "Mounting /dev, /proc, /sys inside chroot: ${SQUASHFS_DIR}"
    mount --bind /dev  "$SQUASHFS_DIR/dev"                         || die "Failed to mount /dev into chroot"
    mount --bind /proc "$SQUASHFS_DIR/proc"                        || die "Failed to mount /proc into chroot"
    mount --bind /sys  "$SQUASHFS_DIR/sys"                         || die "Failed to mount /proc into chroot"
    mount --bind /etc/resolv.conf  "$SQUASHFS_DIR/etc/resolv.conf" || die "Failed to mount /etc/resolv.conf into chroot"
    
    log "Installing packages inside chroot: ${SQUASHFS_DIR}"
    chroot "$SQUASHFS_DIR" /bin/bash -c "
        export DEBIAN_FRONTEND=noninteractive
        apt-get update || exit 1
        apt-get install -y ${packages} || exit 1
    " || die "Failed to install packages inside chroot"

    configure_zram_swap "$SQUASHFS_DIR"
    install_kilocode_cli "$SQUASHFS_DIR"
    install_kilocode_launchers "$SQUASHFS_DIR"
    remove_desktop_install_launcher "$SQUASHFS_DIR"

    log "Unmounting /dev, /proc, /sys inside chroot: ${SQUASHFS_DIR}"
    umount "$SQUASHFS_DIR/dev"             || die "Failed to unmount /dev"
    umount "$SQUASHFS_DIR/proc"            || die "Failed to unmount /proc"
    umount "$SQUASHFS_DIR/sys"             || die "Failed to unmount /sys"
    umount "$SQUASHFS_DIR/etc/resolv.conf" || die "Failed to unmount /etc/resolv.conf"
    
    # Repack squashfs
    log "Removing old squashfs: ${squashfs}"
    rm -f "$squashfs"
    
    log "Repacking squashfs: ${SQUASHFS_DIR} -> ${squashfs}"
    mksquashfs "$SQUASHFS_DIR" "$squashfs" -noappend -comp xz || \
        die "Failed to repack squashfs"
    
    # Clean up
    rm -rf "$SQUASHFS_DIR"
}

configure_zram_swap() {
    local -r rootfs="$1"

    log "Configuring zram swap"

    cat > "$rootfs/etc/default/zramswap" <<'EOF'
# Match the CodeClub live ISO zram setting: compressed swap sized at 50% RAM.
ALGO=lz4
PERCENT=50
PRIORITY=100
EOF

    chroot "$rootfs" /bin/bash -c '
        systemctl enable zramswap.service >/dev/null 2>&1 || true
    '
}

install_kilocode_cli() {
    local -r rootfs="$1"

    log "Installing KiloCode CLI inside chroot"
    if chroot "$rootfs" /bin/bash -c '
        export DEBIAN_FRONTEND=noninteractive
        export npm_config_audit=false
        export npm_config_fund=false
        export npm_config_update_notifier=false
        npm install -g @kilocode/cli
    '; then
        log "KiloCode CLI installed inside chroot"
    else
        log "KiloCode CLI install failed inside chroot; live-session fallback will retry"
    fi
}

install_kilocode_launchers() {
    local -r rootfs="$1"
    local desktop_dir
    local desktop_file

    log "Installing KiloCode launchers"

    mkdir -p \
        "$rootfs/usr/local/bin" \
        "$rootfs/usr/share/applications" \
        "$rootfs/etc/xdg/autostart" \
        "$rootfs/etc/skel/Desktop"

    cat > "$rootfs/usr/local/bin/kilocode-install" <<'EOF'
#!/usr/bin/env bash
set +e

LOG_FILE="${HOME:-/tmp}/kilocode-install.log"
NPM_PREFIX="${HOME:-/tmp}/.cache/npm/global"

{
    echo "KiloCode installer start: $(date)"

    if command -v kilocode >/dev/null 2>&1; then
        echo "KiloCode already available at: $(command -v kilocode)"
        exit 0
    fi

    export NPM_CONFIG_PREFIX="$NPM_PREFIX"
    export npm_config_audit=false
    export npm_config_fund=false
    export npm_config_update_notifier=false
    export PATH="$NPM_PREFIX/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
    mkdir -p "$NPM_PREFIX"

    echo "Waiting for npm registry network access..."
    for attempt in $(seq 1 60); do
        if curl -fsS --max-time 5 -o /dev/null https://registry.npmjs.org/; then
            echo "Network ready on attempt ${attempt}"
            break
        fi
        sleep 5
    done

    for attempt in $(seq 1 10); do
        echo "npm install attempt ${attempt}"
        if npm install -g @kilocode/cli; then
            echo "KiloCode installed at: $(command -v kilocode || true)"
            exit 0
        fi
        sleep 15
    done

    echo "ERROR: KiloCode install failed"
    exit 1
} >> "$LOG_FILE" 2>&1
EOF

    cat > "$rootfs/usr/local/bin/kilocode-wrapper" <<'EOF'
#!/usr/bin/env bash
set +e

export NPM_CONFIG_PREFIX="${HOME:-/tmp}/.cache/npm/global"
export PATH="$NPM_CONFIG_PREFIX/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

if ! command -v kilocode >/dev/null 2>&1; then
    echo "KiloCode is not installed yet. Trying to install it now..."
    echo "Installer log: ${HOME:-/tmp}/kilocode-install.log"
    /usr/local/bin/kilocode-install
fi

if ! command -v kilocode >/dev/null 2>&1; then
    echo
    echo "KiloCode is still unavailable."
    echo "Check ${HOME:-/tmp}/kilocode-install.log, then launch KiloCode again."
    echo
    read -r -p "Press Enter to close..."
    exit 1
fi

exec kilocode "$@"
EOF

    chmod 755 "$rootfs/usr/local/bin/kilocode-install" \
              "$rootfs/usr/local/bin/kilocode-wrapper"

    cat > "$rootfs/usr/share/applications/kilocode.desktop" <<'EOF'
[Desktop Entry]
Name=KiloCode
Comment=AI coding assistant
Exec=x-terminal-emulator -e /usr/local/bin/kilocode-wrapper
Icon=utilities-terminal
Terminal=false
Type=Application
Categories=Development;
StartupNotify=true
EOF

    cat > "$rootfs/etc/xdg/autostart/kilocode-install.desktop" <<'EOF'
[Desktop Entry]
Name=Install KiloCode
Comment=Install KiloCode CLI in the background if needed
Exec=/usr/local/bin/kilocode-install
Icon=utilities-terminal
Terminal=false
Type=Application
X-GNOME-Autostart-enabled=true
EOF

    for desktop_dir in "$rootfs/etc/skel/Desktop" "$rootfs/home/mint/Desktop"; do
        mkdir -p "$desktop_dir"
        desktop_file="$desktop_dir/kilocode.desktop"
        cp "$rootfs/usr/share/applications/kilocode.desktop" "$desktop_file"
        chmod 755 "$desktop_file"
    done
}

remove_desktop_install_launcher() {
    local -r rootfs="$1"
    local removed_count=0
    local desktop_file
    local -a known_install_launchers=(
        "etc/xdg/autostart/ubiquity-mint.desktop"
        "usr/share/applications/ubiquity.desktop"
    )
    local launcher

    log "Removing live desktop installer launchers"

    for launcher in "${known_install_launchers[@]}"; do
        if [[ -e "${rootfs}/${launcher}" ]]; then
            log "Removing installer launcher: ${launcher}"
            rm -f "${rootfs}/${launcher}"
            removed_count=$((removed_count + 1))
        fi
    done

    while IFS= read -r -d '' desktop_file; do
        if grep -Eiq '^(Exec|Name).*ubiquity|only-ubiquity|automatic-ubiquity|install linux mint' "$desktop_file"; then
            log "Removing installer launcher: ${desktop_file#"$rootfs"/}"
            rm -f "$desktop_file"
            removed_count=$((removed_count + 1))
        fi
    done < <(
        find \
            "$rootfs/home" \
            "$rootfs/etc/skel" \
            -path '*/Desktop/*.desktop' \
            -type f \
            -print0 2>/dev/null
    )

    log "Removed ${removed_count} desktop installer launcher(s)"
}

update_manifest() {
    # On non OEM installs the language question is asked during the install procedure.
    # After the system is installed, all packages in the filesystem.manifest-remove
    # list are automatically removed. This includes all language packs except the
    # requested language.
    # Since we're doing an OEM install this leaves us with almost no language packs
    # installed. This causes directories not being localized, missing dictionaries etc...
    # This wouldn't be a problem if the user had a working internet connection but we
    # want to support offline installs.
    # So we're deleting all language packs from this list to make them available during
    # OEM setup
    local -r manifest_path="${BUILD_DIR}/casper/filesystem.manifest-remove"

    log "Preserving language packages in manifest-remove"
    [[ -f "$manifest_path" ]] || die "Manifest-remove file not found: ${manifest_path}"
    
    # Create backup
    cp "$manifest_path" "${manifest_path}.backup"
    
    # Remove language-related packages from removal list
    local -a patterns=(
        '^firefox-locale'
        '^hunspell-'
        '^hyphen-'
        '^language-pack'
        '^libreoffice-'
        '^mythes-'
        '^thunderbird-'
        '^w[^-]*$'
    )
    
    local pattern
    for pattern in "${patterns[@]}"; do
        sed -i "/${pattern}/d" "$manifest_path"
    done
}

build_iso() {
    # The original command that is used to create the official mint iso is recorded
    # on the iso: /.disk/mkisofs
    local -r iso_application_id="$ISO_VOLUME_LABEL"
    local -r modification_date="$(date '+%Y%m%d%H%M%S00')"
    
    log "Building ISO: ${ISO_OUT}"
    
    local -a xorriso_args=(
        -as mkisofs
        -R -r -J -joliet-long -l
        -cache-inodes
        -iso-level 3
        -isohybrid-mbr "$MBR_IMAGE_PATH"
        -partition_offset 16
        -A "$iso_application_id"
        -publisher "$ISO_PUBLISHER"
        -V "$ISO_VOLUME_LABEL"
        --modification-date="$modification_date"
        -c isolinux/isolinux.cat
        -b isolinux/isolinux.bin
            -no-emul-boot
            -boot-load-size 4
            -boot-info-table
        -eltorito-alt-boot
            -e boot/grub/efi.img
            -no-emul-boot
            -isohybrid-gpt-basdat
            -isohybrid-apm-hfsplus
        -o "$ISO_OUT"
        "$BUILD_DIR"
    )
    
    xorriso "${xorriso_args[@]}" || \
        die "Failed to build ${ISO_OUT} from ${BUILD_DIR}"
}

parse_arguments() {
    while getopts ":i:o:p:P:V:m:h" opt; do
        case $opt in
            i) ISO_IN="$OPTARG" ;;
            o) ISO_OUT="$OPTARG" ;;
            p) PRESEED_DIR="$OPTARG" ;;
            P) ISO_PUBLISHER="$OPTARG" ;;
            V) ISO_VOLUME_LABEL="$OPTARG" ;;
            m) MBR_IMAGE_PATH="$OPTARG" ;;
            h) show_usage; exit 0 ;;
            :) show_usage; die "Option -$OPTARG requires an argument" ;;
            *) show_usage; die "Unknown option: -$OPTARG" ;;
        esac
    done
}

main() {
    parse_arguments "$@"
    validate_dependencies
    validate_inputs
    find_mbr_image
    
    create_work_directories
    extract_iso
    copy_preseed_files
    copy_boot_configs
    
    install_packages "$REPO_EXTRA_PACKAGES" "${BUILD_DIR}/casper/filesystem.squashfs"
    
    update_manifest
    update_iso_checksum
    build_iso
    
    log "ISO build completed successfully!"
    log "Output: ${ISO_OUT}"
}

# Only run main if script is executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
