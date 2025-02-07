#!/bin/sh

set -e # terminate on errors
set -x # echo commands

SUITE=$(lsb_release --codename --short)
SRC_DIR="$HOME/src/mesa"
BUILD_OPTS="-Dglvnd=true -Dvalgrind=disabled -Dvulkan-layers=device-select,intel-nullhw,overlay,screenshot"
PACKAGE_MIRROR="http://archive.ubuntu.com/ubuntu"
BUILD_PERFETTO=false
SPIRV_TOOLS_TAG="v2024.4.rc2"
SPIRV_HEADERS_TAG="vulkan-sdk-1.4.304.0"
REV=''

# ref: https://davetang.org/muse/2023/01/31/bash-script-that-accepts-short-long-and-positional-arguments/
usage(){
>&2 cat << EOF
Usage: $0
    [ -s | --suite Ubuntu suite for chroot environment ]
    [ -d | --dir Mesa source directory]
    [ -o | --options Mesa build options ]
    [ -m | --mirror Ubuntu package mirror ]
    [ -p | --perfetto input ]
    [ -r | --revision Mesa revision to build ]
    [ --spirv-tools-tag input ]
    [ --spirv-headers-tag input ]
EOF
exit 1
}

args=$(getopt -a -o s:d:o:m:phr: --long suite:,dir:,options:,mirror:,perfetto,help,spirv-tools-tag:,spirv-headers-tag:,revision: -- "$@")

eval set -- ${args}
while :
do
  case $1 in
    -s | --suite)            SUITE=$2               ; shift 2   ;;
    -d | --dir)              SRC_DIR=$2             ; shift 2   ;;
    -h | --help)             usage                  ; shift     ;;
    -o | --options)          BUILD_OPTS=$2          ; shift 2   ;;
    -m | --mirror)           PACKAGE_MIRROR=$2      ; shift 2   ;;
    -p | --perfetto)         BUILD_PERFETTO=1       ; shift     ;;
    --spirv-tools-tag)       SPIRV_TOOLS_TAG=$2     ; shift 2   ;;
    --spirv-headers-tag)     SPIRV_HEADERS_TAG=$2   ; shift 2   ;;
    -r | --revision)         REV=$2                 ; shift 2   ;;
    # -- means the end of the arguments; drop this, and break out of the while loop
    --) shift; break ;;
    *) >&2 echo Unsupported option: $1
       usage ;;
  esac
done

# make sure source is available
if [ ! -d "$SRC_DIR" ]; then
    mkdir -p $SRC_DIR
fi

SPIRV_TOOLS_SRC_URL="https://github.com/KhronosGroup/SPIRV-Tools.git"
SPIRV_TOOLS_SRC_DIR="$HOME/src/spirv-tools"
SPIRV_HEADERS_SRC_URL="https://github.com/KhronosGroup/SPIRV-Headers.git"
SPIRV_HEADERS_SRC_DIR="$SPIRV_TOOLS_SRC_DIR/external/spirv-headers"

set +e # allow errors temporarily
git -C $SRC_DIR rev-parse 2>/dev/null
exit_code=$(echo $?)
set -e
if [ "$exit_code" -ne 0 ] ; then
    echo "Cloning source..."
    # checkout source
    git clone https://gitlab.freedesktop.org/mesa/mesa.git $SRC_DIR
else
    echo "Source already cloned."
fi

if [ ! "$REV" = '' ] ; then
	git -C "$SRC_DIR" fetch --tags
	git -C "$SRC_DIR" checkout "$REV"
fi

# configure execution-wide state
BUILD_ID=`git -C $SRC_DIR describe --always --tags`

if $BUILD_PERFETTO; then
	BUILD_OPTS="$BUILD_OPTS -Dperfetto=true"
	BUILD_ID="$BUILD_ID+perfetto"
fi

if [ -z "$INSTALL_DIR" ]; then
	INSTALL_DIR=/usr/local-$BUILD_ID
fi

build_mesa() {
	# $1: The schroot architecure
	# $2: The name of the schroot environment
	# $3: The schroot personality
	# ref: https://unix.stackexchange.com/questions/12956/how-do-i-run-32-bit-programs-on-a-64-bit-debian-ubuntu
	SCHROOT_PATH="/build/$SUITE/$1"
	
	sudo apt -y install schroot debootstrap
	sudo mkdir -p $SCHROOT_PATH

	echo "Bootstrapping environment..."
	set +e # debootstrap will return non-zero if the environment has been previously provisioned
	sudo debootstrap --arch $1 $SUITE $SCHROOT_PATH $PACKAGE_MIRROR
	set -e

	echo "Configuring apt..."
	# create minimum viable apt sources
	# ref: https://stackoverflow.com/questions/17487872/shell-writing-many-lines-in-a-file-as-sudo
	sudo sh -c "cat > $SCHROOT_PATH/etc/apt/sources.list" << EOF
deb ${PACKAGE_MIRROR} ${SUITE} universe restricted main multiverse
deb ${PACKAGE_MIRROR} ${SUITE}-updates universe restricted main multiverse
deb ${PACKAGE_MIRROR} ${SUITE}-backports universe restricted main multiverse
deb ${PACKAGE_MIRROR} ${SUITE}-security universe restricted main multiverse
deb-src ${PACKAGE_MIRROR} $SUITE universe restricted main multiverse
deb-src ${PACKAGE_MIRROR} ${SUITE}-updates universe restricted main multiverse
deb-src ${PACKAGE_MIRROR} ${SUITE}-backports universe restricted main multiverse
deb-src ${PACKAGE_MIRROR} ${SUITE}-security universe restricted main multiverse
EOF

	echo "Configuring chroot..."
	sudo sh -c "cat > /etc/schroot/chroot.d/$2" << EOF
[$2]
description=Mesa Build Env
directory=$SCHROOT_PATH
type=directory
personality=$3
groups=users,admin,sudo
EOF
	# setup passwordless sudo
	schroot -c $2 -- sh -c "sudo sed -i 's/\%sudo\sALL=(ALL:ALL) ALL/%sudo   ALL=(ALL:ALL) NOPASSWD:ALL/' /etc/sudoers"

	sudo schroot -c $2 apt update
	# "-- sh -c" required to pass arguments to chroot correctly
	# ref: https://stackoverflow.com/a/3074544
	schroot -c $2 -- sh -c "sudo apt -y --fix-broken install" # sometimes required for initial setup
	schroot -c $2 -- sh -c "sudo apt -y upgrade"
	schroot -c $2 -- sh -c "sudo apt -y build-dep mesa"
	schroot -c $2 -- sh -c "sudo apt -y install git"

	# Handle LLVM
	schroot -c $2 -- sh -c "sudo apt -y install llvm llvm-15"
	# Contemporary Mesa requires LLVM 15. Make sure it's available
	schroot -c $2 -- sh -c "sudo update-alternatives --install /usr/bin/llvm-config llvm-config /usr/lib/llvm-15/bin/llvm-config 200"

	# Handle Rust
	schroot -c $2 -- sh -c "sudo apt -y install curl"
	CARGO_HOME="/usr/local"
	RUSTUP_HOME=$CARGO_HOME
	schroot -c $2 -- sh -c "curl https://sh.rustup.rs -sSf | sudo RUSTUP_HOME=$RUSTUP_HOME CARGO_HOME=$CARGO_HOME sh -s -- -y"
	schroot -c $2 -- sh -c "rustup default stable"
	schroot -c $2 -- sh -c "rustc --version"
	schroot -c $2 -- sh -c "sudo RUSTUP_HOME=$RUSTUP_HOME CARGO_HOME=$CARGO_HOME cargo install bindgen-cli"
	schroot -c $2 -- sh -c "sudo RUSTUP_HOME=$RUSTUP_HOME CARGO_HOME=$CARGO_HOME cargo install cbindgen"

	# Handle SPIR-V tools
	SPIRV_BUILD_DIR="$SPIRV_TOOLS_SRC_DIR/build-$SPIRV_TOOLS_TAG/$1"
	schroot -c $2 -- sh -c "sudo apt -y install cmake"
	schroot -c $2 -- sh -c "git -C $SPIRV_TOOLS_SRC_DIR pull origin main || git clone $SPIRV_TOOLS_SRC_URL $SPIRV_TOOLS_SRC_DIR"
	schroot -c $2 -- sh -c "git -C $SPIRV_TOOLS_SRC_DIR fetch --tags"
	schroot -c $2 -- sh -c "git -C $SPIRV_TOOLS_SRC_DIR checkout $SPIRV_TOOLS_TAG"
	schroot -c $2 -- sh -c "git -C $SPIRV_HEADERS_SRC_DIR pull origin main || git clone $SPIRV_HEADERS_SRC_URL $SPIRV_HEADERS_SRC_DIR"
	schroot -c $2 -- sh -c "git -C $SPIRV_HEADERS_SRC_DIR fetch --tags"
	schroot -c $2 -- sh -c "git -C $SPIRV_HEADERS_SRC_DIR checkout $SPIRV_HEADERS_TAG"
	# Configure
	schroot -c $2 -- sh -c "cmake -B$SPIRV_BUILD_DIR -H$SPIRV_TOOLS_SRC_DIR -DCMAKE_INSTALL_PREFIX=$INSTALL_DIR"
	# Build
	schroot -c $2 -- sh -c "CMAKE_CXX_FLAGS=-m32 LINK_FLAGS=-m32 cmake --build $SPIRV_BUILD_DIR --parallel `nproc`"
	# Install
	schroot -c $2 -- sh -c "sudo cmake --build $SPIRV_BUILD_DIR --target install"

	# Handle miscellaneous deps
	schroot -c $2 -- sh -c "sudo apt -y install libpng-dev"

	# do the build
	cd $SRC_DIR
	BUILD_DIR=build-$BUILD_ID/$1
	mkdir -p $BUILD_DIR
	schroot -c $2 -- sh -c "rm -rf subprojects/libdrm.wrap"
	schroot -c $2 -- sh -c "meson wrap install libdrm"

	schroot -c $2 -- sh -c "PKG_CONFIG_PATH=$PKG_CONFIG_PATH:$INSTALL_DIR/lib/pkgconfig:$INSTALL_DIR/lib/i386-linux-gnu/pkgconfig meson setup $BUILD_DIR $BUILD_OPTS --prefix=$INSTALL_DIR"
	schroot -c $2 -- sh -c "ninja -C $BUILD_DIR"
	schroot -c $2 -- sh -c "sudo ninja -C $BUILD_DIR install"

	# deploy
	sudo cp -Tvr "${SCHROOT_PATH}${INSTALL_DIR}" "$INSTALL_DIR"
}

sudo service gdm3 stop

build_mesa "amd64" "${SUITE}64" "linux"
build_mesa "i386" "${SUITE}32" "linux32"

if $BUILD_PERFETTO; then
	# ref: https://docs.mesa3d.org/perfetto.html
	cd $SRC_DIR/subprojects/perfetto
	./tools/install-build-deps
	./tools/gn gen --args='is_debug=false' out/linux
	./tools/ninja -C out/linux
fi

