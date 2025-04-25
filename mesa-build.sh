#!/bin/sh

set -e # terminate on errors
set -x # echo commands

SUITE=$(lsb_release --codename --short)
SRC_DIR="$HOME/src/mesa"
BUILD_OPTS="-Dglvnd=enabled -Dvalgrind=disabled -Dvulkan-layers=device-select,intel-nullhw,overlay,screenshot -Dintel-clc=enabled -Dintel-rt=enabled -Dtools=intel"
VULKAN_DRIVERS="intel"
GALLIUM_DRIVERS="iris"
PACKAGE_MIRROR="http://archive.ubuntu.com/ubuntu"
BUILD_PERFETTO=false
SPIRV_TOOLS_TAG="v2024.4.rc2"
SPIRV_HEADERS_TAG="vulkan-sdk-1.4.304.0"
REV=''
BUILD_DEBUG='n'
BUILD_DEBUG_OPTIM='n'
BUILD_AMD='n'
BUILD_32='y'
DEPLOY='y'
DEPS='y'

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
	[ -i | --install Path to local install ]
	[ --amd Debug AMD drivers ]
	[ --debug Debug build ]
	[ --dbgoptim Debug optimized build ]
	[ --no32 ]
	[ --nodeploy ]
	[ --nodeps ]
	[ --spirv-tools-tag input ]
	[ --spirv-headers-tag input ]
EOF
exit 1
}

args=$(getopt -a -o s:d:o:m:phr:i: --long suite:,dir:,options:,mirror:,perfetto,help,spirv-tools-tag:,spirv-headers-tag:,revision:,install:,debug,dbgoptim,amd,no32,nodeploy,nodeps -- "$@")

eval set -- ${args}
while :
do
	case $1 in
		-s | --suite)            SUITE=$2               ; shift 2   ;;
		-d | --dir)              SRC_DIR=$2             ; shift 2   ;;
		-h | --help)             usage                  ; shift     ;;
		-o | --options)          BUILD_OPTS=$2          ; shift 2   ;;
		-m | --mirror)           PACKAGE_MIRROR=$2      ; shift 2   ;;
		-p | --perfetto)         BUILD_PERFETTO=y       ; shift     ;;
		--amd)                   BUILD_AMD=y            ; shift     ;;
		--debug)                 BUILD_DEBUG=y          ; shift     ;;
		--dbgoptim)              BUILD_DEBUG_OPTIM=y    ; shift     ;;
		--no32)                  BUILD_32=n             ; shift     ;;
		--nodeploy)              DEPLOY=n               ; shift     ;;
		--nodeps)                DEPS=n                 ; shift     ;;
		--spirv-tools-tag)       SPIRV_TOOLS_TAG=$2     ; shift 2   ;;
		--spirv-headers-tag)     SPIRV_HEADERS_TAG=$2   ; shift 2   ;;
		-r | --revision)         REV=$2                 ; shift 2   ;;
		-i | --install)          INSTALL_DIR=$2         ; shift 2   ;;
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

if [ "$BUILD_PERFETTO" = "y" ]; then
	BUILD_OPTS="$BUILD_OPTS -Dperfetto=true"
	BUILD_ID="$BUILD_ID+perfetto"
fi

if [ "$BUILD_DEBUG" = "y" ]; then
        BUILD_OPTS="$BUILD_OPTS --buildtype=debug"
        BUILD_ID="$BUILD_ID+debug"
elif [ "$BUILD_DEBUG_OPTIM" = "y" ]; then
        BUILD_OPTS="$BUILD_OPTS --buildtype=debugoptimized"
        BUILD_ID="$BUILD_ID+dbg-optim"
else
	BUILD_OPTS="$BUILD_OPTS --buildtype=release"
fi

if [ -z "$INSTALL_DIR" ]; then
	INSTALL_DIR=/usr/local-$BUILD_ID
fi

# handle AMD driver build
if [ "$BUILD_AMD" = "y" ]; then
	VULKAN_DRIVERS="$VULKAN_DRIVERS,amd"
	GALLIUM_DRIVERS="$GALLIUM_DRIVERS,radeonsi"
fi

DRIVER_OPTS="-Dvulkan-drivers=$VULKAN_DRIVERS -Dgallium-drivers=$GALLIUM_DRIVERS"

BUILD_OPTS="$BUILD_OPTS $DRIVER_OPTS"

build_mesa() {
	# $1: The schroot architecure
	# $2: The name of the schroot environment
	# $3: The schroot personality
	# ref: https://unix.stackexchange.com/questions/12956/how-do-i-run-32-bit-programs-on-a-64-bit-debian-ubuntu
	SCHROOT_PATH="/build/$SUITE/$1"

	if [ "$DEPS" = "n" ]; then
		echo "Skipping dependency installation."
	else
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

		# setup git proxy
		if [ -n "$http_proxy" ]; then
			schroot -c $2 -- sh -c "git config --global http.proxy $http_proxy"
		else
			schroot -c $2 -- sh -c "git config --global --unset http.proxy || true"
		fi
		if [ -n "$https_proxy" ]; then
			schroot -c $2 -- sh -c "git config --global https.proxy $https_proxy"
		else
			schroot -c $2 -- sh -c "git config --global --unset https.proxy || true"
		fi

		# Handle LLVM
		schroot -c $2 -- sh -c "sudo apt -y install llvm llvm-15"
		# Contemporary Mesa requires LLVM 15. Make sure it's available
		schroot -c $2 -- sh -c "sudo update-alternatives --install /usr/bin/llvm-config llvm-config /usr/lib/llvm-15/bin/llvm-config 200"

		# Handle Rust
		schroot -c $2 -- sh -c "sudo apt -y install curl"
		CARGO_HOME="/usr/local"
		RUSTUP_HOME=$CARGO_HOME
		schroot -c $2 -- sh -c "http_proxy=$http_proxy https_proxy=$https_proxy curl https://sh.rustup.rs -sSf | sudo http_proxy=$http_proxy https_proxy=$https_proxy RUSTUP_INIT_SKIP_PATH_CHECK='yes' RUSTUP_HOME=$RUSTUP_HOME CARGO_HOME=$CARGO_HOME sh -s -- -y"
		schroot -c $2 -- sh -c "http_proxy=$http_proxy https_proxy=$https_proxy rustup default stable"
		schroot -c $2 -- sh -c "which rustc" # for diagnostics
		schroot -c $2 -- sh -c "rustc --version" # for diagnostics
		schroot -c $2 -- sh -c "rustfmt --version" # for diagnostics
		schroot -c $2 -- sh -c "sudo http_proxy=$http_proxy https_proxy=$https_proxy RUSTUP_HOME=$RUSTUP_HOME CARGO_HOME=$CARGO_HOME cargo install bindgen-cli"
		schroot -c $2 -- sh -c "sudo http_proxy=$http_proxy https_proxy=$https_proxy RUSTUP_HOME=$RUSTUP_HOME CARGO_HOME=$CARGO_HOME cargo install cbindgen"

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
		schroot -c $2 -- sh -c "sudo apt -y install libpng-dev liblua5.3-dev"
	fi

	# do the build
	cd $SRC_DIR
	BUILD_DIR=build-$BUILD_ID/$1
	mkdir -p $BUILD_DIR
	schroot -c $2 -- sh -c "rm -rf subprojects/libdrm.wrap"
	schroot -c $2 -- sh -c "http_proxy=$http_proxy https_proxy=$https_proxy meson wrap install libdrm"
	schroot -c $2 -- sh -c "rm -rf subprojects/wayland-protocols.wrap"
	schroot -c $2 -- sh -c "http_proxy=$http_proxy https_proxy=$https_proxy meson wrap install wayland-protocols"

	schroot -c $2 -- sh -c "http_proxy=$http_proxy https_proxy=$https_proxy PKG_CONFIG_PATH=$PKG_CONFIG_PATH:$INSTALL_DIR/lib/pkgconfig:$INSTALL_DIR/lib/i386-linux-gnu/pkgconfig meson setup $BUILD_DIR $BUILD_OPTS --prefix=$INSTALL_DIR"
	schroot -c $2 -- sh -c "ninja -C $BUILD_DIR"
	schroot -c $2 -- sh -c "sudo ninja -C $BUILD_DIR install"

	# copy to local install directory
	sudo cp -Tvr "${SCHROOT_PATH}${INSTALL_DIR}" "$INSTALL_DIR"
}

if [ "$DEPLOY" = "y" ]; then
	sudo service gdm3 stop

	if [ -d "/usr/local" ]; then
		# mesa-builder deploys Mesa by symlinking /usr/local to the install directory
		# if /usr/local is not a symlink, the user must handle the situation manually
		if [ -L "/usr/local" ]; then
			# we have a symlink; okay to proceed
			sudo rm -f /usr/local
		else
			set +x
			echo "Warning: /usr/local is not a symlink. Deploy cannot continue."
			echo "Please remove /usr/local and re-run the script."
			exit 1
		fi
	fi
fi

if [ "$BUILD_32" = "y" ]; then
	build_mesa "i386" "${SUITE}32" "linux32"
fi
# build 64 bit last so 64b tools are installed
build_mesa "amd64" "${SUITE}64" "linux"

if [ "$BUILD_PERFETTO" = "y" ]; then
	# ref: https://docs.mesa3d.org/perfetto.html
	cd $SRC_DIR/subprojects/perfetto
	./tools/install-build-deps
	./tools/gn gen --args='is_debug=false' out/linux
	./tools/ninja -C out/linux
fi

if [ "$DEPLOY" = "y" ]; then
	sudo ln -sfn $INSTALL_DIR /usr/local
fi
