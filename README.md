# Mesa Builder
Scripts to build and deploy Mesa on Ubuntu using chroot.

Builds are deployed to `/usr/local-$(git describe --always --tags)` by default. `/usr/local` is converted to a symlink that points to the most recent build.

# Configuration

1. Setup proxy environment if needed:
    - `http_proxy`
    - `https_proxy`
    - `no_proxy`
2. Configure environment to use the local Mesa build exclusively:
    ```
    LD_LIBRARY_PATH=/usr/local/lib/x86_64-linux-gnu:/usr/local/lib/i386-linux-gnu
    LIBGL_DRIVERS_PATH=/usr/local/lib/x86_64-linux-gnu/dri:/usr/local/lib/i386-linux-gnu/dri
    # For Intel; update as needed for other platforms
    VK_ICD_FILENAMES=/usr/local/share/vulkan/icd.d/intel_icd.x86_64.json:/usr/local/share/vulkan/icd.d/intel_icd.i686.json
    ```

    For most deployments, these environment variables should be set in `/etc/environment`. Restart the user session (or reboot) to apply the changes.
3. Setup [additional mount points](https://superuser.com/a/676004) in `/etc/schroot/default/fstab` if needed

# Examples

```
# Use an alternate package mirror
~/src/mesa-builder/mesa-build.sh --mirror http://linux-ftp.intel.com/pub/mirrors/ubuntu

# Build a specific Mesa tag (git SHAs work too)
~/src/mesa-builder/mesa-build.sh --revision mesa-24.3.4

# Build the Intel driver only (N.B. this overrides the default options)
~/src/mesa-builder/mesa-build.sh --options "-Dvulkan-drivers=intel"

# Build with Perfetto support
~/src/mesa-builder/mesa-build.sh --perfetto

# Build without deploying
~/src/mesa-builder/mesa-build.sh --nodeploy

# Install to a temporary directory and don't update the /usr/local path
# LD_LIBRARY_PATH, LIBGL_DRIVERS_PATH, and VK_ICD_FILENAMES env vars
# MUST be set properly for workloads to utilize this temporary build 
~/src/mesa-builder/mesa-build.sh --nodeploy --install /tmp/mesa-wip

# Build without building deps (fast, but may fail)
~/src/mesa-builder/mesa-build.sh --nodeps

# Purge everything and start over
git -C ~/src/mesa clean -fxd && sudo rm -rf /build && rm -rf ~/src/spirv-tools && ~/src/mesa-builder/mesa-build.sh

```

# Verify
```
vulkaninfo --summary | grep driverInfo
```

# Work-arounds

```
# The build may crash randomly running on heterogenous cores.
# Pinning the build to P-cores works around this:
taskset -c 0-8 ~/src/mesa-builder/mesa-build.sh
```

```
# clean up lingering mount points from chroot early termination
sudo find /run/schroot/mount/ \( -name proc -o -name pts -o -name home -o -name sys -o -name dev -o -name tmp -o -name secondary_store \) -exec umount {} \;
sudo umount /run/schroot/mount/*
```
