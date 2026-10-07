# Technical notes: macOS guests under KVM on Apple Silicon

Reusable findings from running macOS 13.6 Ventura (22G120) and macOS 26.4
Tahoe (25E246) guests in QEMU's `vmapple` machine under KVM on Fedora Asahi
Remix 44, on M1 Max (t6001) and M1 Ultra (t6002) hosts. The earlier M2 Pro /
Fedora 42 bring-up is described in the README.

## Host kernel

Stock Fedora Asahi `kernel-16k` (7.1.13) plus two patches, built with
`scripts/build-host-kernel.sh` (Fedora spec, patches supplied as
`SOURCES/linux-kernel-test.patch`, a private rpmbuild topdir, a distinct
`buildid` such as `.vmapple2`).

- **`patches/linux-7.1.13-vmapple-pac-vmkey.patch`**: the 6.19 PAuth patch
  regenerated against 7.1.13 (applies with offsets only). It saves/restores
  Apple's implementation-defined `APCTL_EL1`, `KERNKEYLO_EL1` and
  `KERNKEYHI_EL1` in `__sysreg_save/restore_el1_state` and exposes them as
  one-reg descriptors (kept sorted at the end of `sys_reg_descs`). M1 takes the
  `ACTLR_VIRT_APPLE` path; a working host logs
  `ACTLR virtualization (IMPDEF, Apple)` and VHE.
- **`patches/linux-7.1.13-kvm-nisv-ldst.patch`**: XNU's GIC redistributor
  setup uses a pre-indexed store (`str w9, [x8, #128]!`) whose stage-2 abort
  has no valid instruction syndrome (ESR `0x96000010`), which KVM normally
  cannot emulate. The patch resolves the faulting PC with `AT S1E1R` in
  `__get_fault_info()` (while the guest EL1 regime is live), then in
  `io_mem_abort()` reads and decodes single-register LDR/STR (unsigned offset,
  unscaled, pre/post-indexed; V=0), checks the address against FAR,
  synthesises an ISS and applies base writeback. Anything else falls through to
  the old path (`kvm_mmio_nisv` tracepoint). Switch: `kvm.emulate_nisv_ldst`
  (default Y). With it, no GDB hand-off is needed (`INJECT=0`), which also
  saves ~8 s per boot. A traced 10-boot Tahoe loop recorded no declined
  accesses.

Fedora specifics: `/etc/sysconfig/kernel` `UPDATEDEFAULT=yes` makes any newly
installed kernel the default; `scripts/fedora-test-kernel.sh` records and
restores the default and boots a test kernel once with `grub2-reboot`. Arm the
SoC watchdog first (`RuntimeWatchdogSec=30s` in a `system.conf.d` drop-in) so
a hung test kernel falls back to the default entry. KVM is built in
(`CONFIG_KVM=y`), so the patches need a full kernel build, not a module.
A future stock kernel update will become default and lack the patches unless
kernel updates are held.

## QEMU / Reims build

Fedora packages: `ninja-build meson glib2-devel pixman-devel gtk3-devel
vulkan-loader-devel vulkan-headers libslirp-devel libfdt-devel
zlib-ng-compat-devel libepoxy-devel wayland-devel libxkbcommon-devel
gnutls-devel nettle-devel gdb socat qemu-img`, plus cargo/rustc.

- **No crypto backend = stall before launchd.** Without GnuTLS/nettle/gcrypt
  QEMU's AES device fails every keystore command (`cmd_data: Failed to create
  cipher object`, visible with `-d guest_errors -trace aes_*`) and the guest
  idles forever. The build scripts pass `--enable-gnutls`.
- **Renderer.** Reims on the host GPU (Honeykrisp) aborts: Mesa's AGX compiler
  asserts on a 16-bit varying (`value.size == AGX_SIZE_32`). Use llvmpipe:
  `VK_DRIVER_FILES=/usr/share/vulkan/icd.d/lvp_icd.aarch64.json`.
- **Headless polling.** The Reims MMIO shim only started its poll timer
  (`device_poll` + action delivery) when a host window opened. Headless
  (`-display none`), nothing polled the device and Tahoe could block in IOMFB
  swap waits. `qemu-reims-mmio-headless-poll.patch` always starts it.
- **Window suppression.** Reims always tries its host window and falls back to
  the QEMU console only if that fails; with a desktop session present a
  "headless" run opens a window. With `REIMS_VGPU_WINDOW=0` the launcher
  unsets `WAYLAND_DISPLAY`/`DISPLAY`.
- **VNC** needs `pc-bios/keymaps/en-us` built and
  `-L build/qemu-bundle/usr/local/share/qemu`.
- Recent Reims uses `*const i8` for Vulkan extension names, which is `u8` on
  aarch64 Linux: use `std::ffi::c_char`.
- Upstream QEMU removed `hw/arm/machines-qom.h` and the
  `*_machine_interfaces` lists; vmapple uses `.is_available = target_aarch64`.

## macOS 26 (Tahoe) bring-up

Three fixes on top of the Ventura configuration:

- **BDIF disk size.** `REG_NEXT_DEVICE` hard-coded 64 GiB (`0x8000000`
  sectors) for root and 32 MiB for AUX, so AVPBooter panics on a root disk of
  any other size (its backup-GPT read lands at 64 GiB − 512).
  `qemu-vmapple-bdif-disk-size.patch` reports `blk_getlength()/512`.
- **`boot_args` revision 3.** macOS 26 passes revision 3, version 2; the
  revision-2 offsets still describe a valid layout, so the GDB injector
  accepts revision 3 after a plausibility check (device tree inside guest RAM).
- **PAC HVC result in x0.** XNU 26 issues `hvc #0` with `x0=0xc1000000`
  (`SET_INITIAL_STATE`) and spins on `cbnz x0, .`. arm64 KVM ignores
  `run->hypercall.ret`; QEMU must write SMCCC success into x0 itself
  (`qemu-vmapple-pac-hvc-x0.patch`). Ventura never checked.

The GIC store sequence is identical to Ventura's, so the same injector
rewrite or the kernel emulation above applies.

Provisioning (on a macOS host with macosvm):

- With the restore image's default configuration VZ fails at once
  (`VZErrorDomain -9 … Failed to get current host key`): it selects a
  hardware-model descriptor with `DataRepresentationVersion 2`.
  `patches/macosvm-hwmodel-override.patch` adds `MACOSVM_HWMODEL_B64`; forcing
  Ventura's version-1 descriptor (`PlatformVersion 2, MinimumSupportedOS
  13.0.0`) restores 26.4 successfully.
- A fresh 26.4 guest's System and Data volumes are keystore-encrypted, so
  offline pre-seeding (`scripts/macos-preseed-guest.sh`) cannot write the Data
  volume; it still works for unencrypted guests.
- Account creation without a GUI: boot single-user
  (`XNU_BOOT_ARGS="-s -v serial=11 debug=0x14c"`, serial on a Unix socket
  driven by `scripts/serial-shell.py`), then `apfs_boot_util 1;
  apfs_boot_util 2`, `launchctl bootstrap system
  …/com.apple.opendirectoryd.plist`, `dscl .` / `dseditgroup` / `dscl .
  -passwd`, home and `~/.ssh/authorized_keys`, `/var/db/.AppleSetupDone`, a
  sudoers drop-in, and `com.openssh.sshd = false` in launchd's
  `disabled.plist`. (`dscl -f … localonly` fails with eDSUnknownNodeName.)
- AUX: the wrapped `aux.img` is 33,570,816 bytes; skipping 16 KiB leaves the
  32 MiB payload. Boots under VZ modify it, so regenerate the trimmed copy
  after every macOS-side boot.

Headless guest settings baked into images: `pmset -a sleep 0 displaysleep 0
disksleep 0 standby 0 powernap 0`, Spotlight indexing off, screen saver off,
automatic updates off (see limits below), NTP on.

## Metal

Tahoe's paravirtual GPU does attach: IORegistry `gfx@20200000`
(`paravirtualizedgraphics,gpu`) with `AppleParavirtGPU`/`AppleParavirtDisplay`,
and `MTLCreateSystemDefaultDevice()` returns "Apple Paravirtual device". A
runtime-compiled compute kernel ran correctly through Reims on host llvmpipe.
`screendump` stays blank because no login session draws.

`gfx-device=none` (QEMU machine option; `GFX=none` in `launch-kvm.sh`) boots
Tahoe without a paravirtual GPU: no Metal device, the gfx node stays in the
device tree, boot time unchanged (~17 s). It is the better CI default:

- With the GPU, an idle headless guest's WindowServer uses ~82 % of a core
  (software rendering through llvmpipe); without it, 0.4 %.
- Without a GPU, Xcode 26.4.1 builds iOS code (Swift package, `generic/platform=iOS`
  in 26 s, `generic/platform=iOS Simulator` in 8 s), an iOS 26.4.1 simulator
  boots (74 s) and `xcodebuild test` runs XCTest in it (83 s including boot).
- With the GPU, booting an iOS simulator aborted QEMU on the host: llvmpipe's
  LLVM backend cannot compile a `v4f16 = bitcast` in a fragment shader
  ("Cannot select", `fs_variant_partial`). Same FP16 weakness as above,
  reached through a different shader.

## The `avp,rtc` clock

Virtualization.framework guests use `AppleVirtualPlatformRTC`
(`IONameMatch avp,rtc`); QEMU's vmapple only had a PL031, so `timed` logged
"Could not find a matching appleVirtualPlatformService" and "Current RTC
offset is zero. RTC reset likely", and sometimes adopted the image's last
filesystem timestamp.

Reverse engineering (blacktop `ipsw` to extract the VirtualMac2,1
kernelcache and vma2 DeviceTree/iBoot over HTTP ranges, plus objdump):

- **Device tree** `arm-io` contains both `avp-rtc` (reg `0x20240000` + range
  `0x10000000` = **`0x30240000`**, interrupts `[51,0]` = SPI `0x13` with QEMU's
  +32 convention) and `pl031-rtc` (`0x20050000`).
- **iBoot** (iBootStage2 for vma2, base `0x70000000`): at `0x70019834` it reads
  `*(u32 *)0x30240040` and compares with **`0xf001`**. Equal: delete
  `pl031-rtc`; otherwise delete `avp-rtc`.
- **Driver register map:**
  - `0x00`: 64-bit monotonic µs (`getMonotonicTimeUsec`).
  - `getGMTTimeOfDay` = (µs + offset) / 10⁶, offset = NVRAM
    `com.apple.System.rtc-offset`, written by `setGMTTimeOfDay`.
  - `_initRTC`: sets bit 0 of `0x18`, writes `0x00ffffffffffffff` to `0x38`.
  - `_enableRTCInterrupts`: writes 6 to `0x20`.
  - Interrupt path: reads `0x30` (status), writes it back to `0x38` (W1C ack),
    forwards bit 2 / bit 1 to timed's plugin as message 1 / 0.
  - Only this driver registers `kern.monotoniclock_offset_usecs`.

The QEMU model (`hw/vmapple/avp-rtc.c` in the fork) returns host wall-clock µs
since the epoch at `0x00` (so time is correct even with no NVRAM offset),
implements control/enable/status/ack, returns `0xf001` at `0x40`, never raises
an interrupt, and is mapped at `0x30240000` on SPI `0x13` (machine property
`avp-rtc`, default on). With it the guest binds AppleVirtualPlatformRTC,
reports a small negative `kern.monotoniclock_offset_usecs`, and timed
initialises its AVP RTC plugin.

Images baked under the PL031-only QEMU carry no NVRAM RTC offset; re-bake them
once under the `avp,rtc` QEMU (the offset is stored in AUX; layer 45 in
[IMAGES.md](IMAGES.md)).

## Tahoe early-boot stall

Some Tahoe boots reach userspace (APFS, launchd "Early boot complete") but
never answer SSH. Measured per-boot failure rates, GDB-free, retries off:

| Configuration | Failures |
| --- | --- |
| PL031 only, various images | 9–15 % (6/40; 6/61 across mixed loops) |
| `avp,rtc`, image without RTC offset | 5/60 |
| `avp,rtc`, image re-baked with RTC offset (v7) | 5/110 (~4.5 %) |
| v7 on an M1 Ultra host | 0/30 |

Characterisation:

- The guest transmits nothing on the NIC (no DHCP, no ARP reply; slirp keeps
  sending `who-has 10.0.2.15`); `en0` exists but IPConfiguration never runs.
  The missing network is a consequence of a userspace stall.
- Before the RTC fix, failing boots showed launchd timestamps jumping back to
  the image's last shutdown time, then silence. With `avp,rtc` and an image
  carrying an RTC offset, the jump disappears but a second stall remains.
- In remaining stalls 6–7 of 8 vCPUs sit at the same kernel WFI idle PC, all
  virtio queues are drained (`inuse 0`, `signalled-used == used-idx`), and
  the SSH port accepts but sends no banner. The kernel serves devices;
  userspace waits on something internal. Last kernel lines: the
  `IASInstallPhaseList` NVRAM writes, `BootPolicy … security mode`, an APFS
  `tx_flush`.
- Not the cause: vCPU count (4 or 8), legacy vs modern virtio-net, the GDB
  injector vs none, the in-KVM store emulation (the flake reproduces on a
  kernel without it), deleting the timed state plist at bake time (timed
  rewrites it at shutdown), `launchctl disable system/com.apple.timed` (does
  not survive a reboot).

Mitigation: `vm-job.sh` uses a 90 s boot timeout and `BOOT_RETRIES=2`, each
retry from a fresh clone; a failed boot is quit over QMP immediately. A job
then fails only if three boots fail. Good boots reach SSH in 16–24 s.

Diagnostics: `scripts/debug/bootdiag*-install.sh` bake a LaunchDaemon into a
debug golden that logs network/configd/clock state to the serial console.
**Avoid** QMP `x-query-virtio-status` and HMP `info virtio-status` on these
guests: the first crashed QEMU, the second hung the monitor.

## Memory balloon

Tahoe binds Apple's `AppleVirtIOBalloon` to `virtio-balloon-pci` and reads the
target (`num_pages`), and guest free pages do drop, but it never posts page
frames on the inflate queue or writes `actual`, so no host memory is released.
Memory returns to the host only when QEMU exits, which is why jobs use
throwaway guests.

## Disk cache

Guest disks are throwaway clones or promoted only after a clean shutdown, so
`launch-kvm.sh` defaults to `cache=unsafe` (`DISK_CACHE`). Measured in the
guest: 1 GiB write+fsync 194 → 325 MiB/s; small fsync'd files unchanged
(macOS `fsync` is not `F_FULLFSYNC`).

## Guest images and limits

The full build recipe for the images (restore, account, every layer) is in
[IMAGES.md](IMAGES.md); this section records the limits found on the way.

- Command Line Tools install over slirp with `softwareupdate`, no Apple ID
  (Xcode 14.3 CLT on Ventura in ~3 min; Xcode 26.6 CLT on Tahoe in ~3 min).
- Full Xcode needs a user-supplied `.xip`. `xip --expand` in the guest is very
  slow: latency-bound at ~180 file operations/s and <1 % CPU, with Spotlight
  and XProtect scanning alongside; its unpack directory is TCC-protected.
  `xcodebuild -downloadPlatform iOS` fails with "Unable to connect to
  simulator" until CoreSimulatorService has started (~30 s on first use).
  The iOS 26.4.1 runtime is an 8.46 GB MobileAsset from `updates.cdn-apple.com`;
  slirp delivers the host's full speed on wired Ethernet (~25 MB/s, about
  6 min) but ran at ~330 KiB/s on a Wi-Fi host, so bake it on a wired host.
- Spotlight indexing is off on the Data volume, but `mds` stays resident
  (~10 CPU-s per idle 10 min). XProtect's launchd jobs are SIP-protected:
  `launchctl disable` does not persist and `bootout` is refused ("Operation
  not permitted while System Integrity Protection is engaged"). Its everyday
  cost is small (~2 CPU-s per idle 10 min); occasional remediator scans are
  heavier. Disabling it needs SIP off (recoveryOS).
- Software update checks cannot be turned off from inside a 26.4 image:
  `softwareupdate --schedule off` is a no-op and
  `/Library/Preferences/com.apple.SoftwareUpdate` keys are ignored. That needs
  a configuration profile (MDM) or SIP changes. softwareupdated,
  mobileassetd and asset downloads start every boot.
- A second NIC on a tap needs a network service in the guest
  (`networksetup -createnetworkservice LAN en1; -setdhcp LAN`) baked into the
  image; with a stable MAC per slot it keeps the same DHCP lease. The default
  route stays on the user-mode NIC (management path).

## Ephemeral CI runners

Both orchestrators run N slots; each slot loops: register a one-job runner,
boot a fresh clone with `vm-job.sh`, run the runner, discard the guest.
Credentials travel over SSH stdin, never on a command line. Both trap
INT/TERM and signal their process group, so stopping them shuts every guest
down. `vm-job.sh` runs the job SSH session in the background with `<&0` and
`wait`, because bash defers traps until a foreground command returns.

- **GitHub Actions** (`gha-ephemeral-runner.sh`): `POST
  /{repos/O/R|orgs/O}/actions/runners/generate-jitconfig`; the image contains
  `actions-runner` (osx-arm64).
- **Forgejo Actions** (`forgejo-ephemeral-runner.sh`): forgejo-runner has no
  macOS release, so cross-compile it (`GOOS=darwin GOARCH=arm64
  CGO_ENABLED=0 go build -trimpath …`). Node (darwin-arm64) in the image is
  needed for JavaScript actions such as `actions/checkout` in host mode.
  - API mode (Forgejo ≥ 15): `POST /api/v1/{admin|orgs/O|repos/O/R|user}/actions/runners`
    with `{name, description, ephemeral: true}` returns `{id, uuid, token}`;
    the guest runs `forgejo-runner one-job --wait --url … --uuid …
    --token-url file://…`. Leftover registrations are deleted afterwards.
  - Registration-token mode: the guest runs `forgejo-runner register
    --ephemeral` with the instance/org/repo registration token, then
    `one-job --wait`.
  - A Forgejo on the VM host itself is reachable from guests at
    `http://10.0.2.2:<port>` (slirp); set its `ROOT_URL` accordingly.
- Known gap: a slot stopped before it gets a job (service restart, host
  reboot) leaves its ephemeral registration offline in Forgejo until removed
  by an admin; in API mode the orchestrator deletes it.
- systemd units (`systemd/`): run the script via `/usr/bin/bash`, because
  Fedora's SELinux refuses to exec `user_home_t` scripts from a service
  (203/EXEC). `vm-job.sh` ignores further INT/TERM once cleanup starts, so a
  stop (every process gets SIGTERM, then the orchestrator signals its group
  again) still discards each guest and clone. `runner-service.sh` removes
  orphaned run directories at start. `LogFilterPatterns` drops one-job's
  2-second poll lines.

## Linux restore experiment (unfinished)

AVPBooter's virtual DFU device can be bridged to Linux `vhci-hcd` over USB/IP
(`scripts/vmapple-usbip.py`) and identified by libirecovery as
`VirtualMac2,1`; real DFU transfers and a complete iBSS upload were reached,
but the path never produced a bootable guest. Provision on macOS instead.
