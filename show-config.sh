#!/bin/sh

# xargs to trim whitespace
GPU_NAME=$(vulkaninfo --summary | grep deviceName | head -n 1 | cut -d'=' -f2 | xargs)

PCI_ID=$(lspci -vnn | grep -A 1 "VGA" | grep -Eo '\[([0-9a-f]{4}:[0-9a-f]{4})\]' | head -n 1 | tr -d '[]')

echo "- $GPU_NAME $PCI_ID"

KERNEL_VERSION=$(uname -r)

echo "- Linux $KERNEL_VERSION"

DISTRO=$(lsb_release -d -s)

echo "- $DISTRO"

GUC_INFORMATION='NO_GUC_INFORMATION_FOUND'

GUC_INFORMATION=$(sudo dmesg | grep -i 'GuC firmware' | grep -oE 'GuC firmware .*' | head -n 1)
echo "- $GUC_INFORMATION"

MESA_VERSION='UNKNOWN_MESA_VERSION'

CANONICAL_LOCAL=`readlink -f /usr/local`
if [ "$CANONICAL_LOCAL" != "/usr/local" ]; then
	MESA_VERSION="${CANONICAL_LOCAL#\/usr\/}"
else
	MESA_VERSION=$(apt-cache policy mesa-vulkan-drivers | grep Installed: | cut -d: -f2 | xargs)
fi

echo "- Mesa $MESA_VERSION"

PROTON_VERSION=$(cat /mnt/secondary_store/steam/steamapps/common/Proton\ -\ Experimental/version)

echo "- Proton $PROTON_VERSION"
