#!/usr/bin/env bash

set -euo pipefail

# docker_builder.sh runs the build_iso.sh script inside docker.

readonly SCRIPT_DIR="$(dirname $(readlink -f $0))"
readonly CONTAINER_FILE_PATH="${SCRIPT_DIR}/docker/Dockerfile"
readonly BUILD_SCRIPT_PATH="${SCRIPT_DIR}/docker/build_iso.sh"
readonly PRESEED_DIR="${SCRIPT_DIR}/preseed"

readonly ISO_PUBLISHER="Linux Repair Cafe"
readonly DATE_STAMP="$(date '+%Y.%m.%d')"

readonly CONTAINER_NAME="iso_builder"

# Initialize variables to satisfy set -u
ISO_IN=""
ISO_OUT_DIR=""
KEY_ID=""


die() {
    echo -e "\033[31mERROR:\033[0m $1"
    exit 1
}

log() {
    echo -e "\033[32m[$(date '+%Y-%m-%d %H:%M:%S')]\033[0m $1"
}

usage() {
    cat <<EOF
Usage: $(basename "$0") -i <input.iso> -o <output-dir> 

Required arguments:
  -i <input.iso>     Path to the base ISO image
  -o <output-dir>    Directory where the output files will be written

Optional arguments:
  -s <key-id>        Sign checksum with specified key-id
  -h                 Show this help message and exit

Examples:
  $(basename "$0") -i linuxmint.iso -o ./out
EOF
}

parse_args() {
    while getopts ":i:o:s:h" opt; do
        case $opt in
            i) ISO_IN="$OPTARG" ;;
            o) ISO_OUT_DIR="$OPTARG" ;;
            s) KEY_ID="$OPTARG" ;;
            :) usage; die "option -$OPTARG requires an argument" ;;
            h | *) usage; exit 0 ;;
        esac
    done

    if [[ -z "$ISO_IN" || -z "$ISO_OUT_DIR" ]] ; then
        usage
        die "Provide all required arguments!"
    fi

    [[ -f "$ISO_IN" ]] || die "Input iso not found: ${ISO_IN}"
    [[ -d "$ISO_OUT_DIR" ]] || die "Output iso dir not found: ${ISO_OUT_DIR}"

    ISO_IN=$(realpath "$ISO_IN") || die "Failed to get absolute path for: ${ISO_IN}"
    ISO_OUT_DIR=$(realpath "$ISO_OUT_DIR") || die "Failed to get absolute path for: ${ISO_OUT_DIR}"

    if [[ "$(basename ${ISO_IN})" =~ ^linuxmint-([0-9]+\.[0-9]+)-cinnamon-64bit\.iso$ ]] ; then
        ISO_VERSION="${BASH_REMATCH[1]}"
    else
        die "Failed to parse iso filename, expected pattern: linuxmint-{MAJOR.MINOR}-cinnamon-64bit.iso"
    fi

    # ISO volume label should follow iso 9660 standard (32 bytes, [A-Z0-9_])
    ISO_VOLUME_LABEL="LINUX_REPAIR_CAFE_MINT_${ISO_VERSION//./_}"
    ISO_FILENAME="lrc-linuxmint-${ISO_VERSION}-${DATE_STAMP}.iso"
    SHA_FILENAME="lrc-linuxmint-${ISO_VERSION}-${DATE_STAMP}.sha256"
    SIGNED_SHA_FILENAME="lrc-linuxmint-${ISO_VERSION}-${DATE_STAMP}.sha256.gpg"

    for name in "$ISO_FILENAME" "$SHA_FILENAME" "$SIGNED_SHA_FILENAME"; do
        if [[ -e "${ISO_OUT_DIR}/${name}" ]]; then
            die "Output file already exists: ${ISO_OUT_DIR}/${name}"
        fi
    done
}

sign_checksum() {
    # Sign a checksum file with a given GPG key
    local checksum_file="$1"
    local out_file="$2"
    local keyid="$3"

    [[ -f "$checksum_file" ]] || die "File not found: $checksum_file"
    [[ -n "$keyid" ]] || die "GPG key ID not provided"

    local sig_file="${checksum_file}.gpg"

    gpg --armor --local-user "$keyid" --output "${out_file}" --detach-sign "$checksum_file" \
        && log "Signed checksum: ${out_file}" \
        || die "Failed to sign $checksum_file"
}

build_container() {
    # Build container if not exist yet
    local container_file_path="$1"
    local container_name="$2"

    if [[ -z $(docker images --quiet "$container_name") ]]; then
        log "Building container from Containerfile: ${container_file_path}"
        if ! docker build --tag "$container_name" --file "$container_file_path" .; then
            die "Failed to build container from: ${container_file_path}"
        fi
    fi
}

create_checksum() {
    log "Creating sha256sum: ${ISO_OUT_DIR}/${SHA_FILENAME}"
    cd "$ISO_OUT_DIR" ; sha256sum -b "$ISO_FILENAME" > "${ISO_OUT_DIR}/${SHA_FILENAME}"
}

build_iso() {
    log "Building iso: ${ISO_OUT_DIR}/${ISO_FILENAME}"

    local -a docker_args=(
        --privileged
        --rm -it
        -v "${BUILD_SCRIPT_PATH}:/build_iso.sh:ro"
        -v "${ISO_IN}:/input.iso:ro"
        -v "${ISO_OUT_DIR}:/output"
        -v "${PRESEED_DIR}:/preseed:ro"
        -v "/etc/resolv.conf:/etc/resolv.conf:ro"
        "$CONTAINER_NAME"
        /build_iso.sh
    )
    
    local -a build_args=(
        -i "/input.iso"
        -o "/output/${ISO_FILENAME}"
        -p "/preseed"
        -P "${ISO_PUBLISHER}"
        -V "${ISO_VOLUME_LABEL}"
    )
    
    docker run "${docker_args[@]}" "${build_args[@]}" || \
        die "Failed to run build_iso.sh"
}

main() {
    [[ $(command -v docker 2>&1) ]] || die "Docker not found, install first!"

    parse_args "$@"
    build_container "$CONTAINER_FILE_PATH" "$CONTAINER_NAME"
    build_iso
    create_checksum
    [[ -n "$KEY_ID" ]] && sign_checksum "${ISO_OUT_DIR}/${SHA_FILENAME}" \
                                        "${ISO_OUT_DIR}/${SIGNED_SHA_FILENAME}" \
                                        "$KEY_ID"

    log "ISO build completed successfully!"
    log "Output:        ${ISO_OUT_DIR}/${ISO_FILENAME}"
    log "Checksum file: ${ISO_OUT_DIR}/${SHA_FILENAME}"
    log "SHA256:        $(cat "${ISO_OUT_DIR}/${SHA_FILENAME}")"
    [[ -n "$KEY_ID" ]] && log "Signed SHA256: ${ISO_OUT_DIR}/${SIGNED_SHA_FILENAME}"
}

# Only run main if script is executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
