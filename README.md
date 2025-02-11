# Mesa Builder
A script to build a Mesa from a given source revision on Ubuntu using chroot.

# Configuration

1. Setup proxy environment if needed:
    - `http_proxy`
    - `https_proxy`
    - `no_proxy`
2. Setup [additional mount points](https://superuser.com/a/676004) in `/etc/schroot/default/fstab`
3. Configure environment to use the local Mesa build exclusively:
    ```
    LD_LIBRARY_PATH=/usr/local/lib/x86_64-linux-gnu:/usr/local/lib/i386-linux-gnu
    LIBGL_DRIVERS_PATH=/usr/local/lib/x86_64-linux-gnu/dri:/usr/local/lib/i386-linux-gnu/dri
    VK_ICD_FILENAMES=/usr/local/share/vulkan/icd.d/intel_icd.x86_64.json:/usr/local/share/vulkan/icd.d/intel_icd.i686.json
    ```

# Examples

```
# Use an alternate package mirror
~/src/mesa-builder/mesa-build.sh --mirror http://linux-ftp.fi.intel.com/pub/mirrors/ubuntu

# Build a specific Mesa tag (git SHAs work too)
~/src/mesa-builder/mesa-build.sh --revision mesa-24.3.4

# Build the Intel driver only (N.B. this overrides the default options)
~/src/mesa-builder/mesa-build.sh --options "-Dvulkan-drivers=intel"

# Build the Perfetto
~/src/mesa-builder/mesa-build.sh --perfetto
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