#!/bin/sh

git clean -fxd 
cp /boot/config-`uname -r` ./.config 
# remove trusted keys
scripts/config --disable SYSTEM_REVOCATION_KEYS
scripts/config --disable SYSTEM_TRUSTED_KEYS
scripts/config --disable DEBUG_INFO_BTF

# ref: https://superuser.com/a/1748453
scripts/config --undefine GDB_SCRIPTS
scripts/config --undefine DEBUG_INFO
scripts/config --undefine DEBUG_INFO_SPLIT
scripts/config --undefine DEBUG_INFO_REDUCED
scripts/config --undefine DEBUG_INFO_COMPRESSED
scripts/config --set-val  DEBUG_INFO_NONE       y
scripts/config --set-val  DEBUG_INFO_DWARF5     n

yes '' | make oldconfig && make clean && make -j `getconf _NPROCESSORS_ONLN` deb-pkg LOCALVERSION=-`git describe --tags --always | sed 's#/#_#g' | sed 's#_#-#g' | tr '[:upper:]' '[:lower:]'`

