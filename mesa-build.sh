#!/bin/sh

set -e # terminate on errors
set -x # echo commands

if [ -z "$BUILD_OPTS" ]; then
	BUILD_OPTS="-Dglvnd=true"
fi

if [ -z "$SRC_DIR" ]; then
	SRC_DIR="$HOME/src/mesa"
fi

if [ -z "$SUITE" ]; then
	SUITE=$(lsb_release --codename --short)
fi

if [ -z "$PACKAGE_MIRROR" ]; then
	PACKAGE_MIRROR="http://archive.ubuntu.com/ubuntu"
fi

# list of arguments expected in the input
BUILD_PERFETTO=false

while getopts p flag
do
    case "${flag}" in
        p) BUILD_PERFETTO=true;;
    ?)
      echo "Invalid option: -${OPTARG}."
      exit 2
      ;;
    esac
done

# make sure source is available
if [ ! -d "$SRC_DIR" ]; then
    mkdir -p $SRC_DIR
fi

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

	# do the build
	cd $SRC_DIR
	BUILD_DIR=build-$BUILD_ID/$1
	mkdir -p $BUILD_DIR
	schroot -c $2 -- sh -c "meson setup $BUILD_DIR $BUILD_OPTS --prefix=$INSTALL_DIR"
	schroot -c $2 -- sh -c "ninja -C $BUILD_DIR"
	schroot -c $2 -- sh -c "sudo ninja -C $BUILD_DIR install"

	# deploy
	sudo cp -Tvr "${SCHROOT_PATH}${INSTALL_DIR}" "$INSTALL_DIR"
}

build_mesa "amd64" "${SUITE}64" "linux"
build_mesa "i386" "${SUITE}32" "linux32"

if $BUILD_PERFETTO; then
	# ref: https://docs.mesa3d.org/perfetto.html
	cd $SRC_DIR/subprojects/perfetto
	./tools/install-build-deps
	./tools/gn gen --args='is_debug=false' out/linux
	./tools/ninja -C out/linux
fi
