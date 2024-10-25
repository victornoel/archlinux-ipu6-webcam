#!/usr/bin/env bash

set -euo pipefail

RED='\033[0;31m'
ORANGE='\033[0;33m'
NC='\033[0m'
# Insert your AUR package manager and equivalent commands here if any.
# The script will try to use either yay or paru if not specified.
PKGMAN=()
MAKEPKG=(makepkg -si --noconfirm --needed)
# Script flags, best to leave them unless you want to 'hardcode' behaviours.
FLAG_YUY2_WA=false
FLAG_S2DISK_HACK=false
FLAG_EXPLICIT_WAYLAND=false
FLAG_REBOOT_AFTER_INSTALL=false
FLAG_QUIET_MODE=false

SUPPORTED_KERNELS=(linux linux-lts linux-zen linux-hardened)
# All packages installed, in order.
PKGS=(base-devel
  intel-ivsc-firmware
  intel-ipu6-dkms-git
  intel-ipu6ep-camera-bin
  intel-ipu6ep-camera-hal-git
  v4l2loopback-dkms
  v4l2-relayd
  icamerasrc-git
  gst-plugin-pipewire
  gst-plugins-good
)

error() {
  printf "${RED}%s${NC} %s\n" "ERROR:" "${1}"
  exit 1
}

warn() {
  printf "${ORANGE}%s${NC} %s\n" "WARNING:" "${1}"
}

# Configure package manager here if necessary:
if [[ "${#PKGMAN[@]}" -eq 0 ]]; then
  if [[ -x "$(command -v yay)" ]]; then
    PKGMAN=(yay -S --noconfirm --needed)
  elif [[ -x "$(command -v paru)" ]]; then
    PKGMAN=(paru -S --noconfirm --needed)
  elif [[ -x "$(command -v pamac)" ]]; then
    PKGMAN=(pamac install --no-confirm)
  else
    error "\
Couldn't find a package manager, please install either yay, paru, \
pamac or set it manually in the script."
  fi
fi

# Builds the package if a directory with a PKGBUILD is found, or installs it from the AUR/repos if not.
build_and_install() {
  local pkg="${1}"
  if [ -f "${pkg}/PKGBUILD" ]; then
    echo "# Build and install package: ${1}"
    pushd "${pkg}" || error "Somehow unable to go to directory: ${pkg}"
    "${MAKEPKG[@]}" "${pkg}" || error "Failed to build/install: ${pkg}"
    popd || error "Unable to go back to working directory."
    echo "=> SUCCESS"
  else
    echo "# Install package from the AUR/repos: ${pkg}"
    if "${PKGMAN[@]}" "${pkg}"; then
      echo "=> SUCCESS"
    else
      if pacman -Qq "${pkg}"; then
        warn "Package failed to install, but is already installed. Trying to continue."
      else
        error "Couldn't find/unable to install: ${pkg}"
      fi
    fi
  fi
}

# ------------------------------------------------------------------------------
# Handles options
while getopts ":aswrqh" opt; do
  case $opt in
    a)
      echo "Workaround for other applications will be installed."
      FLAG_YUY2_WA=true
      ;;
    s)
      echo "Hibernation workaround will be installed."
      FLAG_S2DISK_HACK=true
      ;;
    w)
      echo "Installing GST plugins for Wayland."
      FLAG_EXPLICIT_WAYLAND=true
      ;;
    r)
      echo "System will reboot after installation."
      FLAG_REBOOT_AFTER_INSTALL=true
      ;;
    q)
      echo "Quiet mode enabled. No installation messages will be printed."
      FLAG_QUIET_MODE=true
      ;;
    h)
      echo "Usage: ${0} [options]"
      echo "Options:"
      echo "  -a          Install workaround for other applications."
      echo "  -s          Install workaround for hibernation."
      echo "  -w          Install GST plugins (bad) for Wayland. Only needed to specify if installing from the TTY."
      echo "              Normally, the script will check \$XDG_SESSION_TYPE to determine if Wayland is used."
      echo "              Right now, you are on '${XDG_SESSION_TYPE}'. If this is empty and you are going to use a Wayland DE, use this option."
      echo "  -r          Reboot after installation. Not recommended unless success is guaranteed."
      echo "  -q          Quiet mode by not printing builds and installs. Also not recommended. (Currently not working.)"
      echo "  -h          Show this help message."
      exit 0
      ;;
    \?)
      echo "Invalid option -$OPTARG" >&2
      echo "Try '${0} -h' for usage." >&2
      exit 1
      ;;
  esac
done

# Need to have the correct headers installed before proceding with DKMS
kernel_exists=false
for kernel in "${SUPPORTED_KERNELS[@]}"; do
  if pacman -Qq "${kernel}" 1>/dev/null 2>&1; then
    echo "# Install headers for: ${kernel}"
    build_and_install "${kernel}-headers"
    kernel_exists=true
  fi
done
$kernel_exists || error "No supported kernel found. Please install one of the following: ${SUPPORTED_KERNELS[*]}"

# Check if Wayland is used
if $FLAG_EXPLICIT_WAYLAND || [ "${XDG_SESSION_TYPE}" = "wayland" ]; then
  echo "# Wayland detected or explicitly requested. Installing 'gst-plugins-bad'."
  PKGS+=(gst-plugins-bad)
fi

# Install all packages in order
for pkg in "${PKGS[@]}"; do
  build_and_install "${pkg}"
done

# Copy workarounds if requested
$FLAG_S2DISK_HACK && sudo install -m 744 workarounds/i2c_ljca-s2disk.sh /usr/lib/systemd/system-sleep/i2c_ljca-s2disk.sh
if $FLAG_YUY2_WA; then
  sudo mkdir -p /etc/systemd/system/v4l2-relayd.service.d
  sudo cp -f workarounds/override.conf /etc/systemd/system/v4l2-relayd.service.d/override.conf
fi

echo "# Enable: v4l2-relayd.service"
if sudo systemctl enable v4l2-relayd.service; then
  echo "=> SUCCESS"
else
  error "Failed to enable: v4l2-relayd.service"
fi
echo "# Start: v4l2-relayd.service"
if sudo systemctl start v4l2-relayd.service; then
  echo "=> SUCCESS"
else
  error "Failed to start: v4l2-relayd.service"
fi

if ! $FLAG_REBOOT_AFTER_INSTALL; then
  echo -e "\n\nAll done.\nRemember to reboot upon succesful installation!"
  read -r -p "Reboot now? [y/N] " ans
  if [ "$ans" = "Y" ] || [ "$ans" = "y" ]; then
    FLAG_REBOOT_AFTER_INSTALL=true
  fi
fi

if $FLAG_REBOOT_AFTER_INSTALL; then
  echo "# Rebooting in 5 seconds..."
  sleep 5
  reboot
else
  echo "# Don't forget to reboot!"
  exit 0
fi
