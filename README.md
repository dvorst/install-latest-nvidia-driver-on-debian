# Install latest Nvidia driver on Debian

Installs the latest NVIDIA driver from NVIDIA's download server and registers it with DKMS. Existing versions are preserved so you can roll back if the new driver has issues.

## Requirements

- Debian-based system
- `curl`, `dkms`, `make`, `gcc`, kernel headers for the target kernel
- Must be run as root

## Usage

```bash
chmod +x install-latest-nvidia-driver.sh
sudo ./install-latest-nvidia-driver.sh
```

## What it does

1. Scrapes `https://download.nvidia.com/XFree86/Linux-x86_64/` to find the latest version
2. Downloads the `.run` file to `/tmp/nvidia-dkms-install/` (skipped if already present)
3. Extracts the kernel source to `/usr/src/nvidia-current-VERSION/`
4. Generates a compatible `dkms.conf`
5. Registers, builds, and installs the module with DKMS
6. Runs `dpkg --configure -a` to clear any pending package configuration

## Rolling back

Old versions are kept in the DKMS tree. To revert:

```bash
sudo dkms uninstall nvidia-current/NEW_VERSION -k <kernel>
sudo dkms install nvidia-current/OLD_VERSION -k <kernel>
```

To see all registered versions:

```bash
dkms status
```

To remove a version you no longer need:

```bash
sudo dkms remove nvidia-current/VERSION --all
sudo rm -rf /usr/src/nvidia-current-VERSION
```

## Notes

- The `.run` file is deleted after a successful install but `/tmp/nvidia-dkms-install/` is kept, so re-running the script after a failed build will not re-download
- If the new version is already registered with an incompatible `dkms.conf`, the script detects this and re-registers automatically
- If the driver fails to build (e.g. due to kernel API changes), patches can be added to `/usr/src/nvidia-current-VERSION/` and a `PATCH[0]="fix.patch"` / `PATCH_MATCH[0]="6\.19"` entry added to `dkms.conf` before re-running
