#!/bin/bash
# NVIDIA DKMS installer - always installs the latest driver version
#
# Usage: sudo ./nvidia-dkms-install.sh [kernel_version]
#   kernel_version defaults to currently running kernel
#
# To roll back to a previous version:
#   sudo dkms uninstall nvidia-current/NEW -k <kernel>
#   sudo dkms install nvidia-current/OLD -k <kernel>

set -euo pipefail

#  config 
KERNEL_VER="${1:-$(uname -r)}"
PACKAGE_NAME="nvidia-current"
DOWNLOAD_BASE="https://download.nvidia.com/XFree86/Linux-x86_64"
WORK_DIR="/tmp/nvidia-dkms-install"
# 

if [[ $EUID -ne 0 ]]; then
    echo "Error: this script must be run as root (sudo)." >&2
    exit 1
fi

echo "==> Fetching latest NVIDIA driver version..."
# Scrape the directory listing rather than using latest.txt, which lags behind.
# Extract version-like directory names (NNN.NNN.NN/ format), sort by version,
# pick the highest.
LATEST_VERSION=$(curl -fsSL "${DOWNLOAD_BASE}/" \
    | grep -oP '[0-9]+\.[0-9]+(\.[0-9]+)?' \
    | tail -1)

if [[ -z "$LATEST_VERSION" ]]; then
    echo "Error: could not determine latest driver version." >&2
    exit 1
fi

echo "    Latest version : ${LATEST_VERSION}"
echo "    Kernel target  : ${KERNEL_VER}"
echo "    Package name   : ${PACKAGE_NAME}"
echo ""

SRC_DIR="/usr/src/${PACKAGE_NAME}-${LATEST_VERSION}"
RUN_FILE="NVIDIA-Linux-x86_64-${LATEST_VERSION}.run"
DOWNLOAD_URL="${DOWNLOAD_BASE}/${LATEST_VERSION}/${RUN_FILE}"

#  warn about existing versions (but leave them alone) 
EXISTING=$(dkms status -m "${PACKAGE_NAME}" 2>/dev/null | awk -F'[,/]' '{print $2}' | tr -d ' ' | sort -uV)
if [[ -n "$EXISTING" ]]; then
    echo "==> Existing DKMS versions found (will be kept for rollback):"
    while IFS= read -r ver; do
        if [[ "$ver" == "$LATEST_VERSION" ]]; then
            echo "      ${ver} (already at latest)"
        else
            echo "      ${ver}"
        fi
    done <<< "$EXISTING"
    echo ""
fi

#  generate_dkms_conf 
# Newer drivers (580+) ship a dkms.conf using __DKMS_MODULES macro syntax
# which older DKMS versions do not support. We always generate our own
# compatible array-based config and save the original as dkms.conf.orig.
generate_dkms_conf() {
    local dir="$1"
    local version="$2"
    local name="$3"

    if [[ -f "${dir}/dkms.conf" ]]; then
        echo "==> Backing up bundled dkms.conf to dkms.conf.orig..."
        cp "${dir}/dkms.conf" "${dir}/dkms.conf.orig"
    fi

    echo "==> Writing compatible dkms.conf..."
    cat > "${dir}/dkms.conf" << EOF
# DKMS configuration for the NVIDIA kernel module.  -*- sh -*-
PACKAGE_NAME="${name}"
PACKAGE_VERSION="${version}"

# Only kernels from 3.10 onwards are supported.
BUILD_EXCLUSIVE_KERNEL="^(3\.[1-9][0-9]|[4-9]\.|[1-9][0-9]\.)"

# The NVIDIA driver does not support real-time kernels.
BUILD_EXCLUSIVE_CONFIG="!CONFIG_PREEMPT_RT !CONFIG_PREEMPT_RT_FULL"

AUTOINSTALL=yes

MAKE[0]="env NV_VERBOSE=1 \\
    make \${parallel_jobs+-j\$parallel_jobs} modules KERNEL_UNAME=\${kernelver}"
CLEAN="true"

BUILT_MODULE_NAME[0]="nvidia"
DEST_MODULE_NAME[0]="\$PACKAGE_NAME"
DEST_MODULE_LOCATION[0]="/updates/dkms"

BUILT_MODULE_NAME[1]="nvidia-modeset"
DEST_MODULE_NAME[1]="\$PACKAGE_NAME-modeset"
DEST_MODULE_LOCATION[1]="/updates/dkms"

BUILT_MODULE_NAME[2]="nvidia-drm"
DEST_MODULE_NAME[2]="\$PACKAGE_NAME-drm"
DEST_MODULE_LOCATION[2]="/updates/dkms"

BUILT_MODULE_NAME[3]="nvidia-uvm"
DEST_MODULE_NAME[3]="\$PACKAGE_NAME-uvm"
DEST_MODULE_LOCATION[3]="/updates/dkms"

BUILT_MODULE_NAME[4]="nvidia-peermem"
DEST_MODULE_NAME[4]="\$PACKAGE_NAME-peermem"
DEST_MODULE_LOCATION[4]="/updates/dkms"
EOF
}

#  check if already registered 
# If the source dir exists but dkms.conf is the broken bundled version,
# we need to re-register with our compatible config. Detect this by checking
# for __DKMS_MODULES in the existing config.
NEEDS_SETUP=true
if dkms status -m "${PACKAGE_NAME}" -v "${LATEST_VERSION}" 2>/dev/null | grep -q "${LATEST_VERSION}"; then
    if grep -q "__DKMS_MODULES" "${SRC_DIR}/dkms.conf" 2>/dev/null; then
        echo "==> ${PACKAGE_NAME}/${LATEST_VERSION} registered but with incompatible dkms.conf."
        echo "    Removing and re-registering with compatible config..."
        dkms remove "${PACKAGE_NAME}/${LATEST_VERSION}" --all 2>/dev/null || true
    else
        echo "==> ${PACKAGE_NAME}/${LATEST_VERSION} already registered with compatible dkms.conf."
        NEEDS_SETUP=false
    fi
fi

if [[ "$NEEDS_SETUP" == true ]]; then
    #  download 
    mkdir -p "${WORK_DIR}"
    if [[ -f "${WORK_DIR}/${RUN_FILE}" ]]; then
        echo "==> ${RUN_FILE} already downloaded, skipping."
    else
        echo "==> Downloading ${RUN_FILE}..."
        curl -fL --progress-bar -o "${WORK_DIR}/${RUN_FILE}.tmp" "${DOWNLOAD_URL}"
        mv "${WORK_DIR}/${RUN_FILE}.tmp" "${WORK_DIR}/${RUN_FILE}"
    fi

    #  extract 
    echo "==> Extracting driver to ${SRC_DIR}..."
    rm -rf "${SRC_DIR}"
    sh "${WORK_DIR}/${RUN_FILE}" --extract-only --target "${SRC_DIR}"

    #  the .run extracts with kernel source in a kernel/ subdir 
    # dkms needs the Makefile at the root of SRC_DIR, so promote it if needed
    if [[ ! -f "${SRC_DIR}/Makefile" && -f "${SRC_DIR}/kernel/Makefile" ]]; then
        echo "==> Kernel source is in kernel/ subdir, promoting to root..."
        cp -a "${SRC_DIR}/kernel/." "${SRC_DIR}/"
    fi

    #  always write our compatible dkms.conf 
    generate_dkms_conf "${SRC_DIR}" "${LATEST_VERSION}" "${PACKAGE_NAME}"

    #  register with dkms 
    echo "==> Registering with DKMS..."
    dkms add -m "${PACKAGE_NAME}" -v "${LATEST_VERSION}"
fi

#  build 
echo "==> Building ${PACKAGE_NAME}/${LATEST_VERSION} for kernel ${KERNEL_VER}..."
dkms build -m "${PACKAGE_NAME}" -v "${LATEST_VERSION}" -k "${KERNEL_VER}"

#  install 
echo "==> Installing ${PACKAGE_NAME}/${LATEST_VERSION} for kernel ${KERNEL_VER}..."
dkms install -m "${PACKAGE_NAME}" -v "${LATEST_VERSION}" -k "${KERNEL_VER}"

#  finish dpkg if needed 
echo "==> Running dpkg --configure -a to finish any pending configuration..."
dpkg --configure -a || true

#  cleanup 
# Remove the .run file but keep WORK_DIR so a re-run doesn't re-download
echo "==> Cleaning up ${RUN_FILE}..."
rm -f "${WORK_DIR}/${RUN_FILE}"

echo ""
echo "Done. ${PACKAGE_NAME}/${LATEST_VERSION} installed for kernel ${KERNEL_VER}."
echo ""
echo "To roll back to a previous version:"
echo "  sudo dkms uninstall ${PACKAGE_NAME}/${LATEST_VERSION} -k ${KERNEL_VER}"
echo "  sudo dkms install ${PACKAGE_NAME}/<old_version> -k ${KERNEL_VER}"
echo ""
echo "Reboot to load the new driver."
