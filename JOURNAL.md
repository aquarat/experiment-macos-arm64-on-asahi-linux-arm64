# Exploration journal

This is a chronological lab notebook. Times are in America/New_York unless noted.

## 2026-08-18 — public experiment README

Reworked `README.md` around the verified result and the shortest reproducible
path for another experimenter. It now records the macOS source path for
`AVPBooter.vmapple2.bin`, the verified firmware and Ventura checksums, private
guest-bundle layout, pinned Reims/QEMU revisions, patched-kernel boundary,
launch command, and current limitations. The three required compatibility
layers are described separately: Apple PAuth state in KVM, VMApple KVM/HVC and
PSCI support in QEMU, and Linux memory/Vulkan behavior in Reims. The runtime
XNU GIC instruction correction is called out explicitly, and the unfinished
Linux DFU/USB/IP work is separated from the known-good macOS-provisioned path.

## 2026-08-17 — Baseline discovery

### Host

- Working tree began empty (only `.git`).
- Host architecture: `aarch64` on Apple M2 Pro (4 Blizzard + 6 Avalanche CPUs).
- Kernel: `6.19.14-400.asahi.fc42.aarch64+16k` on Fedora 42.
- Host page size implied by kernel flavor: 16 KiB; confirm before testing guests.
- `/dev/kvm` exists as `crw-rw-rw- root:kvm`, so unprivileged KVM access is
  available.

Commands used:

```sh
uname -a
lscpu
ls -l /dev/kvm
```

### Apple booter

Found the supplied booter outside the repository:

```text
/home/m1/Downloads/AVPBooter.vmapple2.bin
size:   304352 bytes
sha256: 513ca3fbb2cd5accb0a6da96a5e476d593ebae403d7edb33aebca88f505dac61
```

`file` identifies it only as `data`. Extracted strings include:

```text
AVPBooter for vmapple2 Copyright 2007-2026, Apple Inc.
mBoot-18000.121.3
virt_firmware
Apple Mobile Device (DFU Mode)
```

This is evidence that the file is the expected Apple virtual-platform boot
firmware, not yet evidence that it matches any particular restore image.

### Installed virtualization stack

- `qemu-system-aarch64` and `qemu-img`: QEMU 9.2.4 (Fedora package).
- `virt-install` and `swtpm` are installed.
- `qemu-system-aarch64 -machine help` has no `vmapple` entry.

Conclusion: the distro QEMU cannot boot this platform. QEMU's `vmapple` machine
was merged upstream in March 2025 after the 9.2 release. We will need a newer or
custom-built QEMU with the non-default `vmapple` device configuration enabled.

### Upstream model and artifact gap

Upstream's initial example requires all of the following:

- `AVPBooter.vmapple2.bin` passed with `-bios`;
- a 64-bit machine UUID passed as `-M vmapple,uuid=...`;
- an already-installed macOS root volume;
- its auxiliary (`aux`) volume;
- both volumes attached as pflash and through the corresponding
  `vmapple-virtio-blk-pci` variants.

The upstream implementation initially documented macOS 12 as the supported
guest. Later macOS restore/boot behavior is therefore an explicit compatibility
risk, especially because this booter reports a 2026 build.

Primary references:

- QEMU vmapple machine source and launch example:
  https://gitlab.com/qemu-project/qemu/-/blob/master/hw/vmapple/vmapple.c
- QEMU vmapple documentation:
  https://gitlab.com/qemu-project/qemu/-/blob/master/docs/system/arm/vmapple.rst
- Original technical presentation:
  https://kvm-forum.qemu.org/2023/macOS_in_QEMU_on_ARM_FhJY65D.pdf

### Current hypothesis

The work splits into two independent gates:

1. Build/run a current QEMU with `vmapple` under Linux KVM.
2. Produce a compatible root + aux pair from a legitimately obtained Apple
   UniversalMac restore IPSW. QEMU itself does not perform Apple's
   Virtualization.framework restore workflow.

The next investigation should pin an upstream QEMU revision, verify that
`vmapple` builds with KVM (not only HVF), and audit available open-source
provisioning helpers before downloading an IPSW or creating large disks.

## 2026-08-17 — `experiment-macOS-arm64-on-linux-x86` trial

At the user's direction, cloned the `vmapple-tcg` branch of
https://github.com/steelbrain/experiment-macOS-arm64-on-linux-x86 into the
ignored local build tree.

```text
revision: 509a4ce52bc703dfc79eb8b4283f51acd88b8594
reported QEMU version: 11.1.0
```

The fork is designed for VMApple through TCG on an x86-64 host and contains a
repository-owned firmware smoke test. It also builds KVM support when compiled
on an AArch64 Linux host, so it is a useful starting point for Asahi even though
its documented end-to-end path uses TCG.

`scripts/27on86/build-aarch64.sh` completed successfully on this host and
produced an 82 MiB `build/qemu-system-aarch64`. The resulting binary advertises
`nitro`, `kvm`, and `tcg` accelerators and includes the `vmapple` machine.

The first smoke-test attempt failed before QEMU launch because the harness
hardcoded `clang`, which is not installed. Native AArch64 GCC and
`llvm-objcopy` are installed and are sufficient for the tiny assembly fixture.
The cloned fork's harness was adjusted to fall back to `${CC:-cc}` only when
the build host is AArch64. With that portability fix:

```text
VMApple TCG smoke test: PASS
```

This proves VMApple machine creation and controlled firmware execution through
TCG on the Asahi host. It does not yet prove KVM execution or boot the supplied
Apple firmware. No host package installation was required.

One unrelated command wrapper used the zsh-reserved variable name `status`
after the successful build and consequently returned an error. Subsequent
wrappers use `exit_code`; the QEMU build itself was unaffected.

### KVM isolation

A controlled VMApple KVM run used the same repository-owned smoke firmware as
the passing TCG test:

```text
-machine vmapple,uuid=1,accel=kvm -cpu host -smp 1 -m 1G
result: KVM_RUN returned EINVAL at reset PC 0x100000; no guest instruction ran
```

The same locally built QEMU binary ran a `virt,accel=kvm` control without a
KVM error. Therefore `/dev/kvm`, the binary's AArch64 KVM support, and basic
Asahi KVM execution work; the failure is specific to the VMApple/KVM machine
contract. The fork currently declares VMApple support for `TCG || HVF`, not
KVM, which matches its documented scope. KVM enablement is a new porting task,
not an already-working feature of this branch.

### Supplied AVPBooter with blank disks

Launched the supplied 2026 AVPBooter through the passing TCG path using a
temporary 16 MiB zero-filled aux image and 64 MiB zero-filled root image. The
guest requested a clean shutdown almost immediately and produced no UART text.
Repeating with shutdown converted to pause and QEMU guest-error/unimplemented
logging produced no device error; the CPU remained paused after shutdown.

Conclusion: the real booter is accepted and begins executing, but blank disks
do not constitute a restore/install environment. Progress now requires a
matched, provisioned VMApple aux/root pair plus its ECID. No large artifacts
were downloaded or allocated.

### Unexpected host reboot; KVM tests suspended

While preparing a reversible experiment that changed only VMApple's emulated
GIC addresses to QEMU `virt`-style addresses, the host abruptly rebooted. The
incremental Ninja log shows compilation and linking completed; the modified
binary had **not** been launched. The previous boot's accessible journal ends
without a panic, OOM, or orderly shutdown record, so it does not establish a
cause.

After reboot:

- no QEMU, Ninja, or Meson process remained;
- the experimental address change was reverted without being run;
- further KVM launches and high-load builds were suspended pending caution.

This reboot must not be attributed to the unexecuted GIC layout change. Earlier
VMApple KVM runs did exercise a failing `KVM_RUN` path, however, so a delayed
kernel/hypervisor failure also cannot be excluded from the available evidence.

### Provisioning boundary and native macOS option

Read-only inspection found no existing `aux.img`, VMApple root disk,
`macosvm.json`, or UniversalMac IPSW under `/home/m1`. The internal NVMe does
contain a 75.7 GiB APFS container plus Apple recovery partitions, indicating
that native macOS remains installed.

The upstream `vmapple-bdif` commit explicitly states that USB OTG emulation was
left out because its recovery protocol was not understood. Its source defines
the USB device ID but implements commands only for aux and root block reads.
USB OTG is the interface needed for guest recovery/restore; consequently the
current QEMU machine cannot perform a fresh IPSW restore from Linux merely by
setting `run-installer=on` and attaching blank disks.

Primary source commit:

```text
0179bb3c48cfb915da64305b3cfbc110766d4078
hw/vmapple/bdif: Introduce vmapple backdoor interface
```

A published `idevicerestore` trace confirms that VirtualMac2,1 normally enters
DFU and is restored like a virtual Apple device. Implementing that omitted OTG
contract is a substantial alternative. The shorter provisioning route is to
use Apple's supported Virtualization.framework under the machine's native
macOS installation to create a matched aux/root/ECID bundle, then transfer that
bundle to Linux for the KVM work.

### Host sleep-disable request blocked by interactive sudo

The host is Fedora/Asahi Linux with systemd running. At the user's explicit
request, attempted to persistently disable all systemd sleep modes with:

```sh
sudo -n systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
```

The command made no change because this session cannot supply the required
administrator password:

```text
sudo: a password is required
```

The intended configuration is to mask `sleep.target`, `suspend.target`,
`hibernate.target`, and `hybrid-sleep.target`. This is reversible with
`sudo systemctl unmask` followed by the same four unit names.

### Previous boot ended at suspend entry; no persistent panic record

Privileged evidence supplied after reboot shows the previous kernel log ending
with `PM: suspend entry (s2idle)` at 12:53:55. There is no panic, KVM, or OOM
failure in the supplied tail, and `/sys/fs/pstore` is empty. This reclassifies
the incident as a suspend/resume or remote-reachability failure; it does not
provide evidence that the VMApple KVM experiment crashed the kernel.

### VMApple KVM timer wiring corrected, but first-run EINVAL remains

Static comparison with QEMU's `virt` board found that VMApple wired only
`GTIMER_VIRT` (PPI 27), while KVM-capable ARM boards wire all four architectural
timer outputs. Patched `hw/vmapple/vmapple.c` to use the standard BSA PPIs:

```text
GTIMER_PHYS -> 30  GTIMER_VIRT -> 27
GTIMER_HYP  -> 26  GTIMER_SEC  -> 29
```

Incremental build succeeded, and `scripts/27on86/check-vmapple-tcg.sh` still
passed. A five-second KVM smoke test with the repository's minimal AArch64
firmware still reported `KVM_RUN` `EINVAL` at PC `0x100000`; therefore missing
timer wiring was a real machine-model defect but not the only first-run issue.
Temporarily preserving EL2 under KVM produced the identical result and was
reverted. Logs are under the fork's `build/` and `out/` directories.

### KVM first-entry failure fixed: initialize the requested PMU

QEMU's `-cpu host` requests `KVM_ARM_VCPU_PMU_V3` during vCPU creation. The
VMApple machine did not perform the matching PMU IRQ assignment and PMU device
initialization that QEMU's KVM-capable `virt` machine performs. Linux defers
PMU enablement until the first `KVM_RUN`, explaining why all setup ioctls
succeeded before that call returned `EINVAL`.

Patched VMApple to connect the standard GICv3 maintenance PPI 25 and PMU PPI
23, then call `kvm_arm_pmu_set_irq()` and `kvm_arm_pmu_init()` for KVM vCPUs.
After rebuilding, the five-second KVM smoke command completed guest execution:

```text
-machine vmapple,uuid=1,accel=kvm -cpu host -smp 1 -m 1G
VMAPPLE_TCG_SMOKE_OK
```

The TCG regression also remains passing. Added the reproducible
`scripts/27on86/check-vmapple-kvm.sh` test to the fork. The fix and test are
committed there as `6fdcaa5f20` (`hw/vmapple: initialize KVM PMU and maintenance
IRQ`); the preceding timer wiring correction is `093707843b`.

The supplied AVPBooter was then run for ten seconds with KVM, the known SHA-256
`513ca3fbb2cd5accb0a6da96a5e476d593ebae403d7edb33aebca88f505dac61`, and
small blank aux/root fixtures. It remained running until the controlled timeout
with no UART output or KVM error. A monitor check after three seconds reported
`VM status: running`. This proves the Apple booter executes under KVM; blank
fixtures cannot advance into macOS.

### Reproducible provisioning and KVM launch boundary

Added non-destructive host verification, native-macOS provisioning, ECID
extraction, and Linux KVM launch scripts. Provisioning requires a user-supplied
UniversalMac IPSW (approximately 13 GB) and defaults to a 64 GB sparse guest
disk. The script displays the actual IPSW size and asks before restore. Linux
launch fails early unless `disk.img`, `aux.img.trimmed`, and `vm.json` are
present under the ignored `artifacts/guest/` directory.

The current QEMU fork has inert VMApple graphics MMIO windows on Linux because
upstream `apple-gfx-mmio` uses Apple's host-only graphics framework. Therefore
the immediate next evidence boundary is importing a provisioned guest and
reaching macOS headlessly under KVM; a Linux scanout implementation remains
necessary for the requested GUI.

### Diagnostic tooling and local GUI lead

The user installed `strace-7.0-1.fc42.aarch64`. The PMU fix was identified and
verified before a syscall trace was needed, but the tool is now available for
later KVM ioctl diagnosis.

The sibling `reims-vgpu` checkout contains a `reims-vgpu-mmio` VMApple display
device and explicitly supports a native Linux Vulkan backend; this is a viable
local lead for the GUI phase. Its build wrapper currently rejects AArch64 Linux
as an assumed product matrix restriction even though the Rust backend documents
Linux Vulkan support. No code was copied or changed there. Host prerequisites
already present include Cargo/Rust, Vulkan 1.4.313 development metadata,
`libvulkan.so`, and `vulkaninfo`.

The user subsequently ran the command interactively. Verification with:

```sh
systemctl is-enabled sleep.target suspend.target hibernate.target hybrid-sleep.target
systemctl status sleep.target suspend.target hibernate.target hybrid-sleep.target --no-pager
```

reported all four units as `masked` and inactive. Host sleep is therefore
disabled persistently through systemd.

### Native-Vulkan VMApple GUI build passes on Asahi

Pinned and copied the local `reims-vgpu` checkout at
`2844274c34baa1043d37995f5b1a9f1d265eae03` and its QEMU submodule at
`e17ddb98f71df5697daf2f830587f672a8f4f5a7` into ignored build storage. The
existing wrapper's AArch64/Linux rejection was not a technical backend limit.
The direct QEMU configuration succeeded with:

```text
--target-list=aarch64-softmmu --enable-kvm --enable-gtk
--disable-docs --disable-tools -Dreims_vgpu_backend=vulkan
```

Required integration fixes were: allow VMApple with KVM, apply the proven timer
and PMU initialization, expose current AArch64 X-register reads to the IOSurface
mapper on Linux, and use `std::ffi::c_char` for Vulkan extension pointers on an
architecture where C `char` is unsigned. The resulting QEMU 11.0.50 advertises
both VMApple and `reims-vgpu-mmio`.

A controlled five-second test used KVM, the repository smoke firmware,
`gfx-device=reims-vgpu-mmio`, GTK, and the active Wayland session. Guest output
and display output were both observed:

```text
VMAPPLE_TCG_SMOKE_OK
reims-vgpu-window: first frame presented (1920x1006, 4 swapchain images)
```

The Apple booter also remained running for a controlled ten-second KVM test
with this Vulkan device and blank fixtures, without a KVM or device error. The
patches and guarded multi-GiB build script are now stored in the root repository
so the integration is reproducible. This verifies the host KVM and GUI rails,
but not a macOS-rendered frame; that still requires the provisioned guest bundle.

### Restore metadata pinned without downloading

Queried the ipsw.me `VirtualMac2,1` metadata API and selected the established
Ventura fallback used by the local VMApple work. No IPSW bytes were downloaded.

```text
version: 13.6 (22G120)
file: UniversalMac_13.6_22G120_Restore.ipsw
size: 12,893,555,341 bytes (about 12.0 GiB)
SHA-1: a1675f2c8412122a5e796981571b0269a966708e
URL: https://updates.cdn-apple.com/2023FallFCS/fullrestores/042-55833/C0830847-A2F8-458F-B680-967991820931/UniversalMac_13.6_22G120_Restore.ipsw
```

Added a metadata-only helper and automatic checksum verification for this
pinned filename in the native-macOS provisioning script.

### Provisioning gate rechecked

No IPSW or provisioned `artifacts/guest` bundle is present. The Asahi home
filesystem has 360 GiB available, so the pinned 12.0 GiB download and 64 GiB
sparse guest disk fit comfortably. Host verification and the Vulkan/KVM QEMU
build still pass. Work cannot cross the next boundary without approval for the
large download and a native-macOS `Virtualization.framework` restore, because
the Linux VMApple model does not implement the USB DFU restore transport.

### Native-macOS assumption corrected; Linux DFU work begins

There is no native macOS installation available on this host. The previously
documented `Virtualization.framework` provisioning route therefore cannot be
used locally. After the user approved the pinned IPSW download, it was started
and then stopped when this constraint was clarified. The resumable partial file
was preserved under ignored artifact storage at 1,578,606,592 bytes; no further
IPSW data will be downloaded until the Linux-native restore transport is viable
or the user approves resuming it.

An instrumented `run-installer=on` boot showed that AVPBooter probes a third
BDIF device at `0x30100000` (`DEVID_USB`) after the root and auxiliary devices:

```text
0x30100000 status -> 1
0x30100400 write 1 / read 1
0x30100004 cfg -> 2
```

Current QEMU defines `DEVID_USB` but implements no USB device behavior. Strings
in the user-supplied booter include `virtio-usb`, `virt-usb`, and Apple Mobile
Device DFU mode. This makes implementing and validating the missing BDIF USB
transport on Linux the next prerequisite for a native `idevicerestore`-style
restore. The short trace is retained at
`build/experiment-macOS-arm64-on-linux-x86/out/avpbooter-installer-mmio.log`.

### AVPBooter DFU transport responds on Linux

Adding the guest PC to temporary BDIF traces identified the USB initialization
call in AVPBooter. Unlike the root and auxiliary block devices (`CFG=2`), the
USB device requires `CFG=0x1a01`, declares two queues, and selects command mode
1. Returning that configuration advanced the firmware from its configuration
read to posting a writable receive descriptor:

```text
descriptor table: 0x70071a20
buffer:           0x7006f000
length:           0x80e
flags:            writable
```

The queue protocol uses 16-byte virtqueue-style descriptors. Queue 0 receives
host packets with a six-byte header (`int32 length`, endpoint, transfer type),
and queue 1 returns device packets with a two-byte header (transfer type,
endpoint). A standard USB `GET_DESCRIPTOR(Device)` request sent through this
path returned:

```text
20 01001201000200000040ac052712000002030401
```

After removing the temporary scripted request, QEMU commit `e8714ab84b`
provides an optional framed Unix-socket chardev backend for arbitrary packets.
The repository retains that commit as `patches/vmapple-usb-chardev.patch` and
adds `scripts/probe-vmapple-usb.py`. An end-to-end socket test produced:

```text
USB device 05ac:1227 descriptor=1201000200000040ac052712000002030401
```

This proves AVPBooter is running as an Apple DFU USB device under KVM and that
Linux/QEMU can exchange control transfers with it. The remaining transport
work is to translate USB/IP URBs to these framed packets so libusb-based Apple
restore tools can enumerate and drive the device.

### USB/IP control bridge implemented and exercised

The complete DFU configuration descriptor is 25 bytes and contains one DFU
class interface with no non-control endpoints:

```text
0902190001010580fa0904000000fe0100000721010a000008
```

Therefore AVPBooter's restore protocol needs only endpoint-zero control URBs.
The socket probe now verifies device/configuration descriptors, SET_ADDRESS,
SET_CONFIGURATION, and DFU GETSTATE. After configuration, GETSTATE returned
`02` (`dfuIDLE`).

Added `scripts/vmapple-usbip.py`, a non-privileged USB/IP server which
translates endpoint-zero URBs to the framed AVP transport. It follows the
Linux USB/IP 1.1.1 wire structures documented in the upstream kernel's
`drivers/usb/usbip/usbip_common.h` and tooling sources. An end-to-end test used
the real KVM AVPBooter, QEMU socket backend, bridge import handshake, and a
synthetic USB/IP URB. The USB/IP response contained the exact 18-byte Apple DFU
descriptor:

```text
import reply: version 0x0111, code 0x0003, status 0
USB/IP IN response: 1201000200000040ac052712000002030401
```

The running kernel ships signed `usbip-core.ko.xz` and `vhci-hcd.ko.xz`
modules, but they are not loaded. Fedora package metadata reports
`usbip-5.7.9-12.fc42.aarch64` supplies the missing userspace client. No package
or module change was made. `scripts/launch-dfu.sh` now packages the reproducible
KVM/DFU launch command using only two ignored 16 KiB placeholder disks.

### DFU downloads pass through USB/IP

Validated the data-bearing control-OUT path used by DFU downloads. A disposable
four-byte block was sent to a fresh AVPBooter instance, followed by GETSTATUS:

```text
DFU download reply=0100
DFU GETSTATUS=003200000500
```

The zero status and state 5 indicate `dfuDNLOAD-IDLE` with a 50 ms poll delay.
The same sequence then passed through the complete USB/IP server rather than
the direct socket probe:

```text
SET_CONFIGURATION: status 0
DFU GETSTATE:       status 0, payload 02
DFU DNLOAD (4 B):   status 0
DFU GETSTATUS:      status 0, payload 003200000500
```

This covers both control-IN and control-OUT-with-data translation through
KVM, QEMU BDIF, AVPBooter, and USB/IP. The remaining untested boundary is the
kernel `vhci-hcd` attachment and real libusb/libirecovery enumeration.

### USB/IP client package made optional

Added a guarded `--direct-attach` mode to the bridge. When explicitly run as
root, it chooses only a free high-speed `vhci-hcd` port, creates a private
loopback TCP socket pair, and passes the kernel-side descriptor through the
upstream sysfs `attach` ABI (`port fd devid speed`). It detaches that exact port
on exit. The mode refuses to run without root or an already-loaded module and
does not call `modprobe`; default behavior remains the non-privileged TCP
server. This removes the need to install Fedora's `usbip` client while retaining
wire compatibility.

Fedora metadata shows the remaining restore binaries are small:
`idevicerestore` has a 284.4 KiB installed size and `libirecovery-utils` 68.1
KiB. Their runtime libraries exist in Fedora repositories, but development
metadata is not installed locally, so building equivalent tools from source
would still require additional host packages.

### Post-reboot host-tool and VHCI check

After the host reboot, the user installed the approved recovery tools and
loaded `vhci_hcd`. Verified:

```text
idevicerestore-1.0.0^20240927git511261e-2.fc42.aarch64
libirecovery-utils-1.2.0-2.fc42.aarch64
vhci_hcd 98304 0
usbip_core 81920 1 vhci_hcd
```

The prior QEMU KVM process survived in the current boot and continues to listen
on `/tmp/vmapple-launch-script-test.sock`. All high-speed VHCI ports remain in
state 4 (free), and `irecovery -q` currently reports:

```text
ERROR: Unable to connect to device
```

The direct attach command requires a real root shell because writing the VHCI
`attach` sysfs attribute is privileged. Non-interactive `sudo -n` failed with
`sudo: a password is required`; no host state was changed. The next experiment
is to leave the privileged bridge running against the surviving QEMU socket,
then query it with `irecovery -q` from another shell.

### Linux VHCI enumerates the VMApple DFU device

The user started the direct-attach bridge as root. Linux completed its normal
descriptor sequence and exposed the emulated device:

```text
Bus 005 Device 003: ID 05ac:1227 Apple, Inc. Mobile Device (DFU Mode)
usb 5-1: Product: Apple Mobile Device (DFU Mode)
usb 5-1: Manufacturer: Apple Inc.
```

This validates the complete AVPBooter -> patched QEMU -> framed Unix socket ->
USB/IP -> `vhci_hcd` path using the real kernel USB stack. An unprivileged
`irecovery -q` still failed. `strace` isolated this to host permissions rather
than transport behavior:

```text
openat(AT_FDCWD, "/dev/bus/usb/005/003", O_RDWR|O_CLOEXEC) = -1 EACCES
```

Fedora's installed `/usr/lib/udev/rules.d/39-libirecovery.rules` assigns Apple
DFU products `1222`/`1227` to `root:disk` with mode `0660`; user `m1` is not in
group `disk`. No permission or udev configuration was changed. The next check
is `sudo irecovery -q` while the bridge remains attached.

### libirecovery identifies VirtualMac2,1 through VHCI

With the bridge still attached, `sudo irecovery -q` successfully opened the
device and reported:

```text
CPID: 0xfe00
BDID: 0x20
MODE: DFU
PRODUCT: VirtualMac2,1
MODEL: vma2macosap
NAME: Apple Virtual Machine 1
SRTG: mBoot-18000.121.3
```

This is the first validation with an unmodified Apple recovery client rather
than the repository's synthetic probe. Fedora libirecovery 1.2.0 recognizes
the VMApple board and successfully exchanges DFU control requests across the
entire KVM transport. Exact nonce values were intentionally omitted here.

The pinned Ventura 13.6 restore is 12,893,555,341 bytes. The interrupted
partial file is 1,578,606,592 bytes, leaving 11,314,948,749 bytes (about 10.54
GiB) to download; 384,337,354,752 bytes are free on the filesystem. The IPSW
will supply the signed restore components that `idevicerestore` sends to this
DFU device. No download was started during this check.

### Pinned Ventura IPSW completed and verified

Resumed the previously approved Apple CDN transfer with:

```sh
curl --fail --location --continue-at - \
  --output artifacts/ipsw/UniversalMac_13.6_22G120_Restore.ipsw \
  https://updates.cdn-apple.com/2023FallFCS/fullrestores/042-55833/C0830847-A2F8-458F-B680-967991820931/UniversalMac_13.6_22G120_Restore.ipsw
```

Verification exactly matches the pinned metadata:

```text
size: 12893555341 bytes
SHA-1: a1675f2c8412122a5e796981571b0269a966708e
```

`idevicerestore --ipsw-info` reports macOS 13.6 build 22G120 and includes the
erase identity `ChipID: fe00`, `BoardID: 20`, `Model: vma2macosap`. Upstream
QEMU documentation and the fork's validated macOS 13 fixture establish that
the runtime storage contract is a 32 MiB raw auxiliary pflash payload plus a
root disk. This repository uses a 64 GiB sparse root disk. Neither restore
storage image has been allocated yet.

### Restore storage allocated and AVPBooter restarted

With explicit approval, stopped the disposable QEMU instance and created fresh
ignored restore storage:

```sh
truncate -s 64G artifacts/guest/root.raw
truncate -s 32M artifacts/guest/aux.raw
```

Both files were created with zero allocated filesystem blocks, confirming the
64 GiB root image is sparse rather than consuming its full logical capacity.
Started the KVM installer instance with:

```sh
DFU_STATE_DIR="$PWD/artifacts/guest" \
USB_SOCKET=/tmp/vmapple-restore.sock \
./scripts/launch-dfu.sh
```

The old root-owned VHCI bridge remains attached to the terminated disposable
QEMU socket and must be interrupted from its controlling terminal before the
new restore socket can be attached.

### First real restore reaches iBSS upload

Attached the new restore instance through VHCI and ran Fedora
`idevicerestore 1.0.0^20240927git511261e` against the verified Ventura IPSW:

```sh
sudo idevicerestore -e -y -P -d -R -i 1 \
  artifacts/ipsw/UniversalMac_13.6_22G120_Restore.ipsw \
  2>&1 | tee logs/restore-ventura.log
```

The tool identified `VirtualMac2,1`, selected `Customer Erase Install (IPSW)`,
obtained current Apple SHSH blobs, extracted and personalized iBSS, then hit
the first transport failure:

```text
Sending iBSS (229273 bytes)...
ERROR: Unable to send iBSS component: Unable to upload data to device
ERROR: Unable to send iBSS to device
ERROR: Unable to place device into recovery mode from DFU mode
```

Neither disk has allocated blocks yet, so the restore did not reach storage.
Small DFU downloads were previously proven; the failure is now localized to
the real multi-block iBSS upload or its completion/status sequence. Exact
bridge-side URBs are required for the next patch. Nonce values from the log are
not copied into this journal.

### Real DFU data-phase protocol decoded

Captured the first failing real URB as a 2,048-byte DFU `DNLOAD` request. BDIF
tracing proved AVPBooter accepted the bytes, while USB/IP incorrectly returned
an OUT `actual_length` of zero. Fixed USB/IP OUT completions to report the
submitted byte count.

Size sweeps from fresh AVPBooter processes then showed that payloads through 8
bytes happened to work with transfer type 1, while larger payloads failed.
Testing the BDIF type byte independently established the complete control-OUT
data phase:

```text
SETUP packet type:        1
OUT data packet type:     3
OUT data completion type: 5
```

A fresh 2,048-byte download succeeds for fill bytes `00`, `01`, `55`, `aa`,
and `ff` with type 3. The bridge now uses these phase-specific types and reports
the correct USB/IP transfer length. `scripts/probe-vmapple-usb.py` gained
bounded size, fill-byte, file, and transfer-type experiments so this discovery
is reproducible. `scripts/launch-dfu.sh` gained optional `QEMU_TRACE_FILE`
support for ignored BDIF traces.

### Ventura iBSS rejected by Tahoe-era AVPBooter

With transport errors removed, the personalized Ventura iBSS data phase gets a
valid type-5 completion, but the following DFU GETSTATUS has no status payload.
Uniform 2,048-byte blocks succeed, while an iBSS-shaped block is rejected, so
this is no longer a transport-size failure. `idevicerestore -k` preserved the
229,273-byte personalized iBSS only under ignored `artifacts/personalized/` for
diagnosis.

The supplied booter identifies as `mBoot-18000.121.3`. Current release records
tie that exact firmware to macOS Tahoe 26.5.2 build 25F84, whereas the attempted
IPSW is Ventura 13.6 build 22G120. This cross-generation mismatch is the leading
cause of iBSS rejection. The matching Apple restore image is:

```text
UniversalMac_26.5.2_25F84_Restore.ipsw
size: 19,769,902,281 bytes (about 18.41 GB / 18.4 GiB)
SHA-1: a6dec8ec379533876d8ceea3d82ce482034e24ae
SHA-256: 065abd295a1a456a46c1155217eab92ee95816520ec9aeed83f249f074f68a04
```

The matching Tahoe IPSW was subsequently downloaded from Apple's restore CDN.

### Standing authorization granted

The user removed future approval gates for actions reasonably required to boot
the VM and requested that this be encoded in `AGENTS.md`. The working agreement
now permits autonomous task-scoped downloads, sparse-disk allocation, package
and module operations, permission changes, and experiment process restarts.
Material sizes, purposes, and host mutations must still be reported and
unrelated destructive actions remain out of scope.

### Matching Tahoe restore image verified

Downloaded the exact restore image required by the supplied
`mBoot-18000.121.3` booter:

```sh
curl --fail --location --continue-at - \
  --output artifacts/ipsw/UniversalMac_26.5.2_25F84_Restore.ipsw \
  'https://updates.cdn-apple.com/2026SpringFCS/fullrestores/140-24263/B95838F0-6815-4F0B-A039-156526C081AD/UniversalMac_26.5.2_25F84_Restore.ipsw'
stat -c '%s %n' artifacts/ipsw/UniversalMac_26.5.2_25F84_Restore.ipsw
sha1sum artifacts/ipsw/UniversalMac_26.5.2_25F84_Restore.ipsw
sha256sum artifacts/ipsw/UniversalMac_26.5.2_25F84_Restore.ipsw
idevicerestore --ipsw-info artifacts/ipsw/UniversalMac_26.5.2_25F84_Restore.ipsw
```

The download is exactly 19,769,902,281 bytes. Both published hashes match:

```text
SHA-1:   a6dec8ec379533876d8ceea3d82ce482034e24ae
SHA-256: 065abd295a1a456a46c1155217eab92ee95816520ec9aeed83f249f074f68a04
```

`idevicerestore` reports macOS 26.5.2 build 25F84 and confirms an erase-build
identity for `VirtualMac2,1` (`CPID fe00`, `BDID 20`, model `vma2macosap`).
This closes the firmware-generation mismatch before the next real restore.

### Matching Tahoe iBSS still rejected

Ran the full erase flow with the verified 26.5.2 image, QEMU/KVM DFU guest,
direct VHCI bridge, and the Fedora restore stack:

```sh
sudo idevicerestore -e -y -P -d -R -i 1 \
  artifacts/ipsw/UniversalMac_26.5.2_25F84_Restore.ipsw
```

Apple TSS issued SHSH blobs for the live AP nonce and the tool produced a
320,704-byte personalized `iBSS.vma2.RELEASE.im4p`. AVPBooter again accepted
the type-3 data phase but returned no six-byte DFU status after the first
2,048-byte block:

```text
Sending iBSS (320704 bytes)...
ERROR: Unable to send iBSS component: Unable to get device status
```

The bridge recorded the exact failing pair as block-zero `DNLOAD` followed by
`GETSTATUS`:

```text
dir=0 len=2048 setup=2101000000000008
dir=1 len=6    setup=a103000000000600
```

Repeating with BDIF tracing reproduced it. The firmware-generation mismatch
was real but not the only fault. Leading candidates are malformed/new-format
personalization from the September 2024 Fedora restore stack or an incomplete
BDIF USB data-phase model; both now need isolated tests.

### Empty DFU status translated; complete iBSS upload reached

Corrected an earlier experimental conclusion: the 2,048-byte fill tests had
printed an empty `status=` value without validating its six-byte length, so
they had not actually passed GETSTATUS. Type 3 and its type-5 completion are
still the correct AVP OUT data phase, but AVP returns an empty frame for the
first GETSTATUS after every block. Repeating the request produces DFU
`errNOTDONE`/state 10, showing that the empty frame is a transient virtual-USB
handshake rather than successful status data.

The bridge now maps that empty frame to the normal six-byte
`dfuDNLOAD-IDLE` response (`000000000500`). With this translation,
`idevicerestore` uploaded every block of the 320,834-byte personalized Tahoe
iBSS. The final zero-length DNLOAD returned real state 6
(`dfuMANIFEST-SYNC`); the following GETSTATUS then stopped replying while the
booter waited for reset.

Built current upstream restore tools into ignored `build/restore-prefix` to
exclude Tahoe-era signing/tool compatibility issues:

```text
idevicerestore 45145e9fdc8458022c61a4b87bd029b866d5bcdc
libirecovery   1c495c5aa1ba7fd82cd22f054092fde7979d8532
libtatsu       60a39f36d719344360ec2e87563ed43f61f0530f
libimobiledevice fa0f79190142bc309307967c058f89c1b36eb6b8
```

Installed 26 Fedora build/development packages (7 MiB download, 16 MiB
installed), principally Autotools and the `-devel` packages for plist, USB,
curl, OpenSSL, zip, tatsu, and libimobiledevice. Current `libtatsu` adds the
Tahoe-relevant TSS `Ap,Timestamp` field and newer auth client version; it
changed the ticket and iBSS size but did not change the AVP handshake behavior.

At manifest completion, forwarding an inferred AVP type-zero USB reset and
letting VHCI re-enumerate was insufficient. CPU0 remains in AVPBooter's known
wait-loop instruction at PC `0x10040c`. A QEMU `system_reset` with
`-no-reboot` terminated the VM, as configured. `scripts/launch-dfu.sh` now has
a validated `NO_REBOOT=off` experiment mode so the next run can test whether a
RAM-preserving machine reset consumes the staged iBSS and exposes recovery
USB.

## 2026-08-17: known-good guest image and first KVM XNU/userspace boot

Imported the user-supplied guest archive from `~/Downloads/guest-vm.tar` into
ignored `artifacts/` working copies. The archive is 16,517,564,416 bytes with
SHA-256:

```text
3a9620ef589a32f2ee5706414f21a76a5d9e80ff5ffee741994fd34ecae4424f
```

Its sparse root disk is 68,719,476,736 logical bytes. The 33,570,816-byte AUX
file has a 16 KiB outer wrapper; the QEMU pflash input is the 32 MiB payload
produced with:

```sh
dd if=aux.img of=aux.img.trimmed bs=16384 skip=1 status=progress
```

Installed Fedora's `gdb` package (149 KiB download, 468 KiB installed). Built
LZFSE from upstream commit `e634ca58b4821d9f3d560cdc6df5dec02ffc93fd`
and decompressed the matching Ventura 13.6 (22G120) VMApple kernelcache. The
18,030,167-byte IM4P has SHA-256
`46d41e270f0ffc0da2335ab10d47a108a388534b033b85fde66ae41ff24438c4`;
its decompressed arm64e fileset is 62,734,336 bytes.

With KVM, both one and four vCPUs initially panicked in
`_PE_consistent_debug_register+0x278` on the first GIC redistributor SGI-frame
write. The faulting instruction and syndrome were:

```text
str w9, [x8, #128]!
ESR_EL1=0x96000010 (data abort, ISV=0)
FAR translated by QEMU gva2gpa to 0x10020080 (GICR_IGROUPR0)
```

A new bare-metal KVM probe reads `GICR_TYPER`, wakes the redistributor, and
writes the same `0x81ffffff` value to physical `0x10020080` successfully.
This proves that the in-kernel VGIC works and isolates the failure to KVM's
inability to emulate XNU's pre-indexed MMIO store when the stage-2 abort has
no valid instruction syndrome. Adding the maintenance IRQ property and using
the legacy one-region VGIC redistributor API did not change the panic.

The handoff injector now optionally finds a release-specific, verified
instruction signature through a bounded QMP physical-memory dump and changes
the two stores without modifying the Apple artifact:

```asm
str w9, [x8, #128]!  -> str w9, [x8, #128]
str w9, [x8, #128]   -> str w9, [x8, #256]
```

The transformed sequence preserves both MMIO target addresses. A successful
one-vCPU KVM run used:

```sh
QEMU_27ON86_GDB_PORT=1234 \
QEMU_27ON86_XNU_BOOT_ARGS='-v serial=11 debug=0x14c' \
QEMU_27ON86_KVM_MMIO_PATCH=1 \
QEMU_27ON86_QMP_SOCKET="$PWD/logs/qmp-20260817-183005.sock" \
build/experiment-macOS-arm64-on-linux-x86/scripts/27on86/inject-xnu-boot-args.sh
```

XNU then mounted APFS, validated and grafted the system cryptexes, loaded the
VMApple graphics/storage drivers, and entered PID 1. This is the first native
KVM XNU/userspace boot in this repository. PID 1 currently exits with signal
11 as dyld activates the shared cache, so the graphical Reims window remains
dark and the definition of done is not yet met.

The KVM CPU advertises implementation-defined pointer authentication API
level 4 (`FEAT_FPAC`), while the proven TCG VMApple contract advertises the
original level 1 compatibility behavior. Attempting to lower
`ID_AA64ISAR1_EL1.API` with `KVM_SET_ONE_REG` failed with `EINVAL`; the change
was reverted. This CPU/PAuth boundary and the dyld shared-cache transition are
the next investigation target.

## 2026-08-17: KVM arm64e pointer-authentication compatibility experiments

Cloned the matching XNU source at Apple tag `xnu-8796.141.3`, commit
`1b191cb58250d0705d8a51287127505aa4bc0789`, under ignored `build/`. Decoding
the user saved state at XNU's terminal user-abort path proved that launchd's
first crash was an arm64e import call: a dyld stub loaded an unsigned raw
pointer and executed `braa x16, x17`; KVM/FEAT_FPAC poisoned it. This matches
the TCG experiment journals' explicit compatibility behavior of accepting or
stripping pointer signatures that TCG cannot validate.

Added an opt-in runtime experiment, `QEMU_27ON86_KVM_PAUTH_BYPASS=1`, to the
ignored QEMU worktree's handoff injector. It locates exact Ventura XNU
signatures, uses hardware GDB breakpoints at the user-abort and `handle_pac_fail`
paths, and returns through `arm64_thread_exception_return` after repairing the
saved user state. Recovery required changing only the final mismatch branch in
`ml_check_signed_state` to a NOP; modifying a signed saved PC otherwise causes
`JOP Hash Mismatch`. This deliberately weakens guest pointer/JOP integrity and
is an experimental boot compatibility mechanism, not a security-preserving
solution.

Clean reflink runs `pauth-bypass-run4` through `run22` successively identified
and handled these observed arm64e forms:

```text
BRAA x16,x17 import stub -> BR x16
AUTIA x16,x17            -> XPACI x16
AUTDA x16,x17            -> XPACD x16
BLRAAZ x8                -> BLR x8
BLRAA Xm,Xn              -> BLR Xm
BRAAZ x3                 -> BR x3
```

GDB memory writes do not reliably invalidate the guest instruction cache, so
the handler also recognizes repeat faults from cached original instructions.
Run 22 (`logs/serial-20260817-191548.log`) passed launchd's initial import
activation, dozens of dyld calls, both newly reached `AUTDA` sites, generalized
`BLRAA x8,x17`, and repeat cached `BLRAA` execution. Its next boundary was a
tail `braa x3,x16` at user VA `0x102f247f8`, immediately after an `AUTDA` at
`0x102f247c8`; because a tail branch preserves LR, the earlier LR-based source
locator could not find it. The next injector revision tracks the most recent
direct FPAC site, scans the following 128 bytes, validates the branch target
against the saved register file, and rewrites that tail branch to `BR`.

Runs 23 through 27 generalized tail `BRAA`, `BLRAAZ`, modifier-register forms
of `AUTIA`/`AUTDA`, and nested authenticated branches. They exposed a critical
semantic error in the first approach: rewriting `BRAA` to `BR` is valid only
while a dyld slot contains an unsigned pointer. Once dyld emits signed
pointers, `BR` preserves the PAC bits and jumps to an invalid address. The TCG
fork's actual `pauth_impdef_compat` behavior in
`target/arm/tcg/pauth_helper.c` instead calls `pauth_original_ptr()` on every
authentication. Run 30 stopped rewriting branch instructions and emulated
that strip-and-continue behavior in saved state. It stayed alive through more
than 43,000 authenticated calls, proving the semantics but also proving that a
GDB round trip per call is not a usable runtime design.

The matching XNU source contains an explicit AppleVirtualPlatform comment in
`osfmk/arm64/sleh.c`: a host can implement ARM FPAC without any way to disable
or trap it, so guest kernels must contain an FPAC handler. Based on that design,
run 31 installed two release-signature-verified runtime trampolines into the
loaded XNU image before first execution:

- `handle_pac_fail` now strips the saved destination register selected by the
  faulting `AUTIA`/`AUTDA`, advances saved PC by four, and returns to userspace;
- `handle_user_abort` now recognizes a PAC-poisoned instruction target when
  saved PC equals FAR, strips it, and returns; all ordinary faults replay the
  displaced `pacibsp` and enter the original function.

The trampolines occupy the now-unreachable body of `handle_pac_fail`, use exact
Ventura prologue verification, and branch through the previously identified
`arm64_thread_exception_return`. The existing JOP mismatch branch compatibility
patch remains required because these handlers modify signed saved state. With
`QEMU_27ON86_KVM_PAUTH_IN_GUEST=1`, GDB detached immediately after handoff and
run 31 reached the `-s` single-user shell. The upstream E0006 headless bootstrap
then uploaded all SSH assets successfully and began APFS Data-volume/service
setup. This is the first KVM run to execute the TCG-proven provisioning flow
without a persistent debugger.

## 2026-08-17: APFS ordering and KVM userspace PAC diagnostics

Rechecked the AUX inputs after the host crash. The pristine 32 MiB payload is
produced from the archive's wrapped AUX with `bs=16384 skip=1` and has SHA-256
`3ac1a8837b0ac04fd49beb4e90f31f30b09630caca839cd04a3a0a68ab2fa9af`.
The earlier diagnostic clone had already been mutated by boot and is not a
valid clean template.

The E0006 bootstrap's direct `apfs_boot_util 2` invocation was incomplete on a
fresh KVM boot. Running phase 1 first, followed by phase 2, mounts Data and
establishes the `/private` firmlink in approximately one second:

```sh
/System/Library/Filesystems/apfs.fs/Contents/Resources/apfs_boot_util 1
/System/Library/Filesystems/apfs.fs/Contents/Resources/apfs_boot_util 2
```

The phase-1 `Log volume mount failed - error c05d. Ignoring...` and phase-2
`c002` diagnostics are non-fatal. The ignored experiment bootstrap now runs
phase 1 before phase 2; this must be carried into the tracked reproducible
flow.

After Data was mounted, `com.apple.configd` consistently launched through
`xpcproxy` and then exited due to SIGSEGV. `networksetup` did the same, leaving
only `lo0`, `gif0`, and `stf0`. A hardware breakpoint at the real runtime
`handle_user_abort` address captured one downstream ordinary EL0 data abort:
ESR `0x9200004f`, FAR `0x148e03f9a`, PC `0x19e0581f0`, instruction
`strh wzr, [x9, x10]`, with `x9=0x148e00070` and `x10=0x3f2a`.

The first in-guest FPAC trampoline decoded every `handle_pac_fail` instruction
destination from bits 0..4. That is wrong for system AUT encodings, whose low
bits are 31: `AUTIA1716`/`AUTIB1716` target x17, while the SP/Z forms target
x30. The trampoline now recognizes the `0xd503` system prefix and selects x17
or x30 rather than corrupting saved SP. Run 36 proved that correction boots
but does not by itself keep configd alive.

Tracing run 36 at `handle_user_abort=0xfffffe00141fb050` showed hundreds of
EL0 instruction aborts with ESR `0x82000004`; saved PC equaled FAR and carried
varying PAC bits, while stripping to 40 bits always selected mapped arm64e
code. The handler recovered those faults, but configd eventually reached a
real data abort (for example ESR `0x92000047`, FAR `0x16db23f50`, PC
`0x1a9fb23dc`, `stp q0, q0, [x0]`) and died. This confirms that reactive
authentication repair is incomplete even though it crosses launchd/dyld.

Ventura publishes EL0 features from its sole `mrs x12, ID_AA64ISAR1_EL1` at
physical dump offset `0x47483ec`. Run 37 replaced that instruction with
`mov x12, #0x100`, making the commpage advertise the TCG-compatible PAuth API
level 1 and no PAuth2/FPAC. The patch verified and the guest booted, but configd
still exited with SIGSEGV. Advertising API 1 is therefore insufficient; the
remaining incompatibility is the actual VMApple PAC signing/key contract.

As a separate negative control, `-cpu host,pauth=off` was accepted by QEMU but
left AVPBooter looping at PC `0x10040c`, so globally disabling KVM PAuth is not
a viable handoff configuration.

Run 38 used the Reims vGPU QEMU, omitted `-s`, and installed the same GIC and
in-guest PAuth patches before a normal boot. The vGPU presented a 1920x1006
frame, but a QMP screendump after more than 40 seconds remained entirely black;
normal boot has therefore not yet met the GUI checkpoint. Run 39 repeated the
headless setup with a full 60-second phase-2 settle before starting configd.
Configd still exited with SIGSEGV, ruling out premature APFS notification
settling as the cause.

An opt-in QEMU experiment initialized APIA, APIB, APDA, APDB, and APGA low/high
KVM registers to zero after `KVM_ARM_VCPU_INIT`. The VM started with all ten
`KVM_SET_ONE_REG` operations succeeding, but run 40 without the reactive XNU
PAuth handler did not reach a single-user prompt. Merely choosing a fixed raw
architectural key does not reproduce VMApple's PAC contract.

The host kernel supports `KVM_SMCCC_FILTER_FWD_TO_USER`. After correcting the
interface to use `KVM_SET_DEVICE_ATTR` with group `KVM_ARM_VM_SMCCC_CTRL`, run
41 forwarded the Apple CPU-service range `[0xc1000000, 0xc1000100)` and observed
this initial call sequence:

```text
0xc1000000  VMAPPLE_PAC_SET_INITIAL_STATE
0xc1000001  VMAPPLE_PAC_GET_DEFAULT_KEYS
0xc10000f0  VMAPPLE_PAC_NOP (four calls)
0xc1000003  VMAPPLE_PAC_SET_B_KEYS (repeated during context switches)
```

Arm KVM does not populate `kvm_run.hypercall.args[]`; its API requires reading
guest GPRs with `KVM_GET_ONE_REG`, so the first diagnostic printed zero argument
placeholders. This forwarding path is nevertheless the first clean userspace
interception point for implementing VMApple's private PAC service. The next
experiment must retrieve x1-x3 explicitly and determine whether the required
EL0-only diversifier can be represented without changing XNU's EL1 keys.

## 2026-08-17: TCG experiment records and VMApple PAC ABI

Read the fork's experiment records under `docs/experiments/`, especially
E0004 through E0006. Those records establish that the working TCG path
generates deterministic signatures with a fixed zero implementation-defined
key across vCPUs and accepts every authentication while stripping the
signature. This is the exact compatibility contract that KVM must reproduce
or replace with faithful VMApple PAC virtualization.

Run 43 forwarded `[0xc1000000, 0xc1000100)` with
`KVM_ARM_VM_SMCCC_FILTER` and read x1-x3 explicitly using
`KVM_GET_ONE_REG`. Ventura called `SET_INITIAL_STATE`, `GET_DEFAULT_KEYS`,
`NOP`, `SET_B_KEYS`, and `SET_EL0_DIVERSIFIER_AT_EL1`. Matching XNU
`8796.141.3` confirms that function 5 uses x1 as the enable flag and x2 as the
user JOP key or saved state.

The first userspace implementation returned zero in x2 and x3 for
`GET_DEFAULT_KEYS`; previously x3 retained a kernel pointer from the call
site, which XNU recorded as its default JOP PID. Run 44 used the pristine AUX
payload SHA-256
`3ac1a8837b0ac04fd49beb4e90f31f30b09630caca839cd04a3a0a68ab2fa9af`, a
reflink of the known guest disk, one vCPU, the GIC correction, and the
in-guest reactive PAC handlers. It reached the single-user shell and all
subsequent function-5 calls carried x2=0, proving the output ABI fix took
effect. After APFS phases 1 and 2 plus the upstream 60-second settle,
`com.apple.configd` still exited, no service remained in launchd, and only
lo0/gif0/stf0 existed. Correct default outputs are necessary but not
sufficient.

For the next implementation step, cloned Asahi's `m1n1` at
`53f8ee9b54ba52b7f87e607e8206a8c827f06b04` into
`build/m1n1-pac-research` as a 6.8 MiB shallow checkout. Its Apple register
database identifies the hardware facility VMApple is abstracting:
`KERNKEYLO_EL1/HI_EL1` are Apple pointer-authentication kernel keys, with EL2
aliases `KERNKEYLO_EL12` and `KERNKEYHI_EL12` encoded as
`S3_6_C15_C2_3` and `S3_6_C15_C2_4`. The next experiment is to test whether
the Asahi KVM vCPU one-register API exposes those EL12 registers. If so, the
private HVC service can preserve separate kernel and userspace diversification
instead of overwriting the architectural APIA/B keys shared by EL0 and EL1.

### KERNKEY probe and post-fault recovery boundary

Run 45 (`artifacts/hvc-kernkey-probe-run45`) added a read-only KVM
`KVM_GET_ONE_REG` probe for the Apple EL2 aliases identified by m1n1. All
three returned `ENOENT`: `APCTL_EL12` (`S3_6_C15_C15_0`),
`KERNKEYLO_EL12` (`S3_6_C15_C2_3`), and `KERNKEYHI_EL12`
(`S3_6_C15_C2_4`). The stock
`6.19.14-400.asahi.fc42.aarch64+16k` KVM one-register ABI therefore does not
expose this vendor state to QEMU.

Runs 47 and 48 (`artifacts/pauth-data-recovery-run47` and
`artifacts/pauth-data-recovery-run48`) extended the in-guest abort trampoline
to scan saved x0-x28 for an exact match to a high PAC-tagged data FAR, strip
the tag, and retry. A first assembler-encoding error in the CBZ/CBNZ branches
was corrected and independently checked with `llvm-mc`/`llvm-objdump`; the
corrected direct-boot form still failed to reach the single-user shell and
entered the kernel halt path after userspace started.

Run 49 (`artifacts/pauth-delayed-data-run49`) booted with the established
instruction-fault-only trampoline, reaching the shell with
`handle_user_abort=0xfffffe00153b3050`,
`handle_pac_fail=0xfffffe00153b3508`, and
`exception_return=0xfffffe0015240998`. The extended trampoline was then
installed live. Bootstrap entered a sustained fault loop instead of reaching
SSH. GDB captured ordinary low-address EL0 aborts, including ESR
`0x92000006`, FAR `0xedb630`, saved PC `0x19f97d3d4`, with saved x10 equal to
the FAR at `cas w17, w16, [x10]`; another recurring site was an `ldrb` loop.
Reactive high-FAR repair can therefore turn immediate crashes into later
logical corruption, but cannot reproduce the signing relationship expected
by macOS. QEMU PID 100586 and its socat console were stopped with SIGINT/TERM
after the capture.

### Matching Asahi kernel source acquired

The exact installed devel package name is architecture-specific. These first
attempts failed and are retained as useful package-resolution evidence:

```text
dnf install kernel-devel-$(uname -r)  # no matching package
dnf install kernel-devel              # conflicts with Asahi kernel metapackage
```

Installed instead:

```sh
sudo dnf install kernel-16k-devel-6.19.14-400.asahi.fc42.aarch64 patch
```

This also installed `bison`, `flex`, and `elfutils-libelf-devel`; the kernel
devel transaction downloaded approximately 21 MiB and installed 85 MiB, and
`patch` downloaded 112 KiB and installed 263 KiB. The matching Fedora/Asahi
source RPM was downloaded and unpacked under ignored
`build/asahi-kernel-src/`:

```text
file: kernel-6.19.14-400.asahi.fc42.src.rpm
size: 163976367 bytes
sha256: 51211791b58db2aa613038c6ed083f52bad16c15c774070e40e645cbcc0490c0
```

Its source archive and `patch-6.19-redhat.patch` were expanded and applied to
`build/asahi-kernel-src/tree` (approximately 2.0 GiB including the SRPM and
tree). Inspection confirms Asahi carries Apple ACTLR virtualization, but KVM's
PAuth context only saves architectural APIA/APIB/APDA/APDB/APGA pairs. It does
not save, restore, or expose APCTL/KERNKEY. m1n1 at
`53f8ee9b54ba52b7f87e607e8206a8c827f06b04` explicitly redirects guest
`KERNKEYLO_EL1/HI_EL1` to their EL12 aliases, providing the model for the next
kernel experiment.

### Custom Asahi KVM VM-key kernel built and installed

The Fedora source patch requires the separately shipped `Makefile.rhelver`, so
the exact file from the extracted SRPM was copied into the source root before
applying `patch-6.19-redhat.patch`. The installed kernel configuration was
copied from `/boot/config-6.19.14-400.asahi.fc42.aarch64+16k` and normalized
with `make olddefconfig`; its SHA-256 is
`d09e3daeb198e38483be17229c0d3da8b5f5969c5c07e50a63f4e409d09fdd6a`.

Added the tracked, reversible kernel patch
`patches/linux-6.19-vmapple-pac-vmkey.patch` (1,477 bytes, SHA-256
`972fdb453571508f8b2e195f059583194e7d514ba4b03c108df02a9719a38ae3`).
On Apple CPUs with ACTLR virtualization, the KVM guest restore path now writes
the same fixed VM key and APSTS state used by m1n1 before entering a guest:

```text
VMKEYLO_EL2 = 0x4e7672476f6e6147
VMKEYHI_EL2 = 0x697665596f755570
APSTS_EL12  = 1
```

This does not yet add a userspace one-register ABI or virtualize KERNKEY; it is
a deliberately narrow test of whether the missing Apple hardware VM-key setup
accounts for KVM's incompatible PAC behavior. The reverse dry-run succeeded:

```sh
patch --dry-run -R -p1 < patches/linux-6.19-vmapple-pac-vmkey.patch
```

Built the complete Fedora configuration successfully with:

```sh
make -C build/asahi-kernel-src/tree LOCALVERSION=-vmapple1 -j8 Image modules
make -C build/asahi-kernel-src/tree LOCALVERSION=-vmapple1 -j8 vmlinuz.efi
make -C build/asahi-kernel-src/tree LOCALVERSION=-vmapple1 -j8 dtbs
```

The resulting release is `6.19.14-vmapple1`. The raw 16 KiB-page ARM64 Image
is 57,215,488 bytes with SHA-256
`435c14e4906ef4badf3e7841cb9c7a2b0e33ab0e981f8beb96d92710c7a7d29c`.
The EFI wrapper is 14,574,080 bytes with SHA-256
`c5a96d3e1d26673355e61e241612da9d0b647020bbd118d7818e83a405d25688`.

Installed modules and DTBs alongside the stock kernel with:

```sh
sudo make -C build/asahi-kernel-src/tree LOCALVERSION=-vmapple1 modules_install
sudo make -C build/asahi-kernel-src/tree LOCALVERSION=-vmapple1 \
  INSTALL_DTBS_PATH=/usr/lib/modules/6.19.14-vmapple1/dtb dtbs_install
sudo make -C build/asahi-kernel-src/tree LOCALVERSION=-vmapple1 install
```

The first install attempt failed before changing boot files because
`arch/arm64/boot/vmlinuz.efi` had not been built. The second stopped in
`15-update-m1n1.install` because the DTB install had not yet run. After DTBs
were installed, m1n1 updated successfully and GRUB configuration generation
succeeded. Fedora's later rescue hook then failed while trying to create a
redundant rescue initramfs:

```text
cp: error writing '/boot/initramfs-0-rescue-a148644741844863b4388880aeaa9a2c.img': No space left on device
dracut[F]: Creation of /boot/initramfs-0-rescue-a148644741844863b4388880aeaa9a2c.img failed
```

The failed hook removed its partial initramfs. Its new dangling rescue entry
and rescue kernel copy were explicitly removed, and `grub2-mkconfig -o
/boot/grub2/grub.cfg` was rerun. Both stock kernels remain untouched, and
GRUB's saved entry remains
`a148644741844863b4388880aeaa9a2c-6.19.14-400.asahi.fc42.aarch64+16k`.
The usable custom initramfs is 70,691,263 bytes with SHA-256
`c00ea47ed35d2d6b7666a7a9ec44a4e188d5cf92561f6713be69f0f163b24dc3`;
505 MiB remains free on `/boot`.

`grubby --info=ALL` reports the custom BLS entry as index 0 with ID
`a148644741844863b4388880aeaa9a2c-6.19.14-vmapple1`. Set that ID for the next
boot only using `grub2-reboot`; `saved_entry` remained the stock 6.19.14 Asahi
kernel. This makes a failed custom boot recover to stock on the following
power cycle.

### VM-key kernel boot and first clean KVM retest

The host returned successfully on the one-shot custom entry:

```text
Linux ... 6.19.14-vmapple1 #1 SMP PREEMPT_DYNAMIC Mon Aug 17 21:53:09 EDT 2026 aarch64
```

Run 50 (`artifacts/vmkey-run50`) used one KVM vCPU, a fresh reflink of the
known-working macOS 13 disk, pristine trimmed AUX SHA-256
`3ac1a8837b0ac04fd49beb4e90f31f30b09630caca839cd04a3a0a68ab2fa9af`,
QEMU's KVM HVC forwarding, and only the established XNU GIC correction. It
did not use API-version spoofing, pointer-authentication bypasses, or in-guest
PAuth handlers. The guest reached launchd, then reported:

```text
pid 1 exited -- exit reason namespace 2 subcode 0xb
panic: initproc failed to start
```

The complete serial record is `artifacts/vmkey-run50/serial.log`. Establishing
the APVMKEY/APSTS hardware state is therefore necessary but not sufficient.

### Apple PAuth virtualization contract recovered

A sparse documentation clone of public XNU research was placed under ignored
`build/darwin-xnu-vmapple-doc` at commit
`f96c754925a29fd61ad611fe49c565b8799a4921` (approximately 2.5 MiB). Its
VMApple PAuth contract describes HVC functions 0 through 6: initialize state,
get defaults, set A, set B, set the EL0 diversifier, enable that diversifier at
EL1, and set G.

Apple's public XNU tag `xnu-7195.60.75`, commit
`76670bb0cc455cc16dc9a9d943d2feb09508d309`, supplies the exact old-hardware
mapping. With B input `0xfeedfacefeedfacf`, APIB/APDB receive input through
input+3, KERNKEY receives input+4 and input+5, APIA/APDA receive input+6
through input+9, and APGA receives input+10 and input+11. APCTL uses AppleMode
bit 0, KernKeyEn bit 1, EnAPKey0 bit 2, EnAPKey1 bit 3, and UserKeyEn bit 4.
The initial/EL0-only value is `0x19`; enabling the EL0 diversifier at EL1 uses
`0x1b`.

### Custom Asahi KVM Apple PAuth-context kernel vmapple2

The ignored kernel worktree now gives APCTL_EL1 and KERNKEYLO/HI_EL1 dedicated
KVM context slots, saves and restores their EL12 hardware aliases, and exposes
them through the ARM one-register ABI when Apple ACTLR virtualization is
available. QEMU's opt-in `QEMU_VMAPPLE_KVM_HVC=1` path now implements the full
HVC 0-6 contract above and writes the architectural A/B/G keys plus the new
APCTL/KERNKEY registers. The rebuilt QEMU completed cleanly with:

```sh
ninja -C build/experiment-macOS-arm64-on-linux-x86/build qemu-system-aarch64
```

The kernel and modules completed with:

```sh
make -C build/asahi-kernel-src/tree LOCALVERSION=-vmapple2 -j8 Image modules
make -C build/asahi-kernel-src/tree LOCALVERSION=-vmapple2 -j8 vmlinuz.efi
```

`6.19.14-vmapple2` was installed alongside the stock kernel. The rescue-only
dracut configuration was moved aside for the install and restored immediately
afterward. Installed artifacts are:

```text
/boot/vmlinuz-6.19.14-vmapple2
size: 14569984
sha256: 4e07d97938382f11da94f901e47683c059744dd15dc53423745cf713111c6b94

/boot/initramfs-6.19.14-vmapple2.img
size: 70637978
sha256: b01ee77fee5370a9344c842f118adfbe220129de7f75884c0d00aba889175848
```

GRUB's saved default remains the stock Asahi entry; vmapple2 will again be
selected for one boot only.

### TCG experiment journals identify the SSH setup contract

Read all records under the nested QEMU tree's `docs/experiments/`. E0004
records repeatable macOS 13 launchd boot; E0005 records reliable eight-vCPU
boot; E0006 records authenticated SSH and workloads. Crucially, SSH was not
already enabled in the guest image. `validate-headless.py` pauses QEMU, injects
`-s -v serial=11 debug=0x14c` and CSR configuration `0x2` at XNU handoff, then
uses the single-user serial shell to mount the Data volume, wait for APFS
firmlinks, start the minimum network/directory services, install temporary
keys, and bootstrap a private sshd. The KVM validation must reproduce this
handoff/bootstrap sequence rather than merely probe forwarded TCP port 22.

The supplied `/home/m1/Downloads/guest-vm.tar` is 16 GiB on disk and contains
a 32,570,816-byte wrapped AUX image, a 64 GiB sparse root disk, and `vm.json`.
Its VM metadata exactly matches `artifacts/working-guest/vm.json` and
`artifacts/known-working-run/vm.json` (SHA-256
`3d35c0f326c42617e8d724cf602139d8870f3477f16b9f720bc69b3ff2f8061d`).
The four-vCPU, 8 GiB source VM is therefore the known TCG-proven input, not a
separate native-macOS installation.

### Run 51 exposes an M2 capability-guard error

The host booted `6.19.14-vmapple2` successfully. Run 51
(`artifacts/vmapple-pac-run51`) used pristine reflinks and the full PAC HVC
QEMU path, but stopped at the first HVC because all three new one-register IDs
returned `ENOENT`:

```text
VMApple PAC register APCTL_EL12 unavailable: No such file or directory
VMApple PAC register KERNKEYLO_EL12 unavailable: No such file or directory
VMApple PAC register KERNKEYHI_EL12 unavailable: No such file or directory
```

This was not an ID-encoding mismatch. Kernel boot output identifies the host
capability as `ACTLR virtualization (architectural?)`. M2 and newer CPUs set
`ARM64_HAS_ACTLR_VIRT`, whereas the new PAC visibility/save/restore and VM-key
blocks tested only the older `ARM64_HAS_ACTLR_VIRT_APPLE` capability. Thus the
vmapple1 and first vmapple2 kernels never executed their new hardware path on
this M2 host. m1n1's CPU-generation-aware implementation confirms that
APVMKEY, APSTS, APCTL, and KERNKEY remain applicable while only ACTLR's alias
selection changes.

Widened the PAC guards to accept either ACTLR virtualization capability and
incrementally rebuilt the same `6.19.14-vmapple2` release:

```sh
make LOCALVERSION=-vmapple2 -j8 Image vmlinuz.efi
```

The corrected Image is 57,215,488 bytes with SHA-256
`54fbf73fade2da2c4b912069116d21edca731263c39ef5156bf64b29de23e6bd`.
The corrected EFI kernel is 14,524,928 bytes with SHA-256
`d138985f578be94454d40bf70c25fca8f5031d61a0977394f7c9657525a845d3`.
Because the release and module ABI are unchanged, the installed vmapple2 EFI
kernel alone was replaced; the prior EFI was retained as
`/boot/vmlinuz-6.19.14-vmapple2.pre-m2-guard` with SHA-256
`4e07d97938382f11da94f901e47683c059744dd15dc53423745cf713111c6b94`.
The existing initramfs and modules remain valid, and 410 MiB remains free on
`/boot`.

### Run 52 reaches stable macOS userspace with native Apple PAC

The corrected vmapple2 kernel booted as build `#3`. Run 52 used one KVM vCPU,
fresh known-working reflinks, normal verbose boot, the GIC MMIO correction,
and no pointer-authentication bypass or in-guest compatibility handler. At the
first PAC HVC, KVM successfully exposed all new registers at reset value zero:

```text
VMApple PAC register APCTL_EL12=0
VMApple PAC register KERNKEYLO_EL12=0
VMApple PAC register KERNKEYHI_EL12=0
```

QEMU then initialized the defaults and serviced XNU's repeated B-key changes
(HVC 3) and KERNKEY/APCTL EL0/EL1 switches (HVC 5). XNU entered normal
userspace, launchd emitted two `Darwin Bootstrapper Version 7.0.0` notices
across its userspace reboot, process identifiers progressed to approximately
300, and QMP remained `running`. No `pid 1 exited`, `initproc failed`, or panic
appeared. This is the first clean KVM boot with the actual Apple hardware PAC
contract rather than signature stripping or recovery handlers. Full serial:
`artifacts/vmapple-pac-run52/serial.log`.

### Run 53 boots macOS with the Reims graphical QEMU but no guest frame yet

Ported the proven SMCCC forwarding and PAC HVC 0-6 implementation into the
existing Reims QEMU fork at `ef0465ce1e161706da0430219a4d552969b32f70`.
The incremental Ninja build completed successfully; the resulting
`qemu-system-aarch64` SHA-256 is
`b308c1f70e67c9e0fee9d628ed8f875219e7286c8cd7e273c073374549dd8fb1`.

Run 53 used fresh reflinks and `gfx-device=reims-vgpu-mmio`. The GTK/Wayland
host window initialized and presented a 1920x1006 four-image swapchain. PAC
HVCs completed, and macOS again reached stable launchd userspace without a
panic. QMP screendump, however, remained completely black:

```text
artifacts/vmapple-gui-run53/screen.ppm
size: 6220817
sha256: a8aaf2a0a91b2ff218775a0d2b6a229c9c4488dce4f835689a24559f9f414490
```

The copied device census `artifacts/vmapple-gui-run53/reims-vgpu-fail.log`
shows zero guest GPU packets, zero objects, zero presents, and repeated
`no_frame` windows. The host Vulkan/backend and display loop are alive, but
the guest AppleParavirtGPU path has not attached or brought a display online.
The next run will use E0006's exact single-user serial bootstrap to obtain SSH
and inspect the guest's IORegistry, loaded kexts, launch services, and logs.

## 2026-08-17 — normal macOS GUI boot achieved with KVM and Reims

### Upstream state and prior experimental evidence

Verified that the local Reims checkout is current with upstream rather than an
outdated fork:

```text
reims-vgpu master: 2844274c34baa1043d37995f5b1a9f1d265eae03
vendored QEMU host-reims-vgpu-vmapple: e17ddb98f71df5697daf2f830587f672a8f4f5a7
```

Read the experiment journals under the QEMU repository, especially E0006.
Its SSH result was not a preconfigured service: it used single-user mode to
bootstrap remote diagnostics. This distinction matters because Apple disables
services, kexts, and other facilities in single-user mode. Runs 55 onward used
normal multi-user boot for GPU diagnosis, and the final GUI result does not
claim single-user mode as evidence.

### Runs 54–55: normal-userspace GPU failure isolated

Run 54 reproduced E0006's single-user bootstrap only to install
`/Library/LaunchDaemons/org.qemu.27on86.sshd.plist` on the supplied disk. Run
55 then booted normally and provided the first useful live IORegistry view.
WindowServer and loginwindow were running, but `AppleParavirtGPU` was neither
registered nor matched. Reims received seven setup packets, then failed every
completion-stamp mapping with `qemu_map_pages_callback_failed` on one-page
guest physical ranges.

The cause was an explicit non-Darwin stub in `reims-vgpu-mmio.c`: `map_pages`
always returned `-1` on Linux. The Linux implementation now validates that the
range is RAM and host-contiguous, then returns a stable RAMBlock alias. This is
adequate for the completion-stamp pages requested by this guest and is tracked
in `patches/reims-qemu-linux-arm64.patch`.

### Runs 56–57: software Vulkan FP16 crash isolated

With Linux page mapping implemented, Run 56 brought the Reims display online
and progressed into guest rendering, then QEMU aborted in Mesa's llvmpipe JIT:

```text
LLVM ERROR: Cannot select: v4i16 = bitcast v4f32
In function: fs_variant_partial
```

Run 57 repeated the test with `GALLIVM_PERF=nopt`. It compiled and drew much
farther but eventually hit the same fatal selection error. Host inspection
showed Mesa 25.3.6 and LLVM 20.1.8, with only llvmpipe available. The custom
kernel configuration omitted `CONFIG_RUST` and `CONFIG_DRM_ASAHI`, so there is
no Asahi render node under `/dev/dri`; only the DCP display card is present.

Reims now treats a Vulkan physical device of type CPU conservatively and
advertises `native_fp16=false` to the guest. This prevents the Apple GPU plugin
from selecting the llvmpipe-incompatible native-FP16 shader path while leaving
hardware Vulkan capability reporting unchanged. The fix is tracked in
`patches/reims-rust-linux-arm64.patch`.

### Run 58: verified normal-mode graphical boot

Run 58 used KVM, one vCPU, 8 GiB RAM, the normal command line
`-v serial=11 debug=0x14c`, CSR configuration `0x2`, the XNU GIC instruction
correction, native Apple PAC HVC handling, and the Reims GTK/Vulkan display.
It was explicitly a normal multi-user boot, not single-user mode.

The guest reports macOS 13.6 build 22G120. `WindowServer`, `loginwindow`, and
Language Chooser are running. IORegistry shows both `AppleParavirtGPU` and its
`AppleParavirtDisplay` child as registered, matched, and active; WindowServer
and Language Chooser own Metal user clients. Reims negotiated a 1920x1080
display and continuously publishes fresh non-black frames, typically 13–29
presents per second under llvmpipe. Representative live output:

```text
device_info host_fp16=0 derived=[key9=0(was 1)]
display_shared_state_setup
display_online_signal
display_online_ack
display_enable_mask
OFF present_content mid=14 1920x1080 ... rgb_nz=486997 max_rgb=255 ...
```

QMP also captured the rendered white Apple logo on black:

```text
artifacts/vmapple-gui-run58/screen.ppm  12,493 bytes
sha256 8d61a9f589304bec5b227efa04115d3cf779a0281be978af9140fe8150c6aa8e
artifacts/vmapple-gui-run58/screen.png  1,127 bytes
sha256 6b4dc00e6105cd4e76ce6ebbf2d86785472f135953ea7f5438bcdcfabb66011e
```

The run's guest state census is
`artifacts/vmapple-gui-run58/guest-render-state.txt` (9,840 bytes, SHA-256
`01fce7e1856fce9e638fa9b6e3ee0d59b450ba1387d3749fa83ba880e9a96858`).
The fixed-point copy of the Reims log is 5,868,749 bytes, SHA-256
`b0ae93559fc993ef2d77637de208c3f5299ac2f6dde9120fc12867bf15e1bc9a`.
The successful QEMU binary is 150,260,896 bytes, SHA-256
`db87598b12c2394ef146aa58351d55d9e4fd6ea91a0a795a85155a063ac6ac6e`.

### Reproducible source products

Regenerated the complete source patches and verified that each applies to its
pinned source checkout:

```text
patches/linux-6.19-vmapple-pac-vmkey.patch
  4,268 bytes; sha256 b523a4c81e2291614a60884590241316c436fc670beedd3a0a9a22fd9d270a23
patches/reims-qemu-linux-arm64.patch
  16,898 bytes; sha256 59d5e7bab424f390793b03c772690f4c8658fb10d615c51c19e5513ab3e993fd
patches/reims-rust-linux-arm64.patch
  1,506 bytes; sha256 f960273eeb7a46c7d4eafe1ad5fd118da2293846f3d93810ac21908acfe028fe
```

Added `scripts/launch-gui-kvm.sh` and the self-contained
`scripts/inject-xnu-kvm.sh`/`.gdb` handoff injector. The launcher starts QEMU
paused, injects boot arguments and CSR state, applies the exact GIC MMIO
instruction correction, detaches GDB, and leaves QEMU in the foreground with
persistent serial/QMP logging. `scripts/apple_device_tree.py` contains the
minimal flattened Apple device-tree editing support. `scripts/launch-kvm.sh`
now opts into the patched VMApple PAC HVC contract through
`QEMU_VMAPPLE_KVM_HVC=1`.

Final verification after the host reboot:

```text
$ bash -n scripts/*.sh
(no output; PASS)
$ python3 -m py_compile scripts/apple_device_tree.py
(no output; PASS)
$ scripts/check-host.sh
architecture: aarch64
kernel: 6.19.14-vmapple2
KVM: accessible
VMApple KVM host check: PASS
```

The Reims Rust patch passes `git apply --check` at upstream commit
`2844274c34baa1043d37995f5b1a9f1d265eae03`. The QEMU patch passes the same
check in a clean detached worktree at
`e17ddb98f71df5697daf2f830587f672a8f4f5a7`. The kernel patch was dry-run
against the exact Fedora/Asahi 6.19.14 source. `git diff --check` passes for
the repository changes. A repeat ShellCheck run was unavailable because the
rebooted host currently has no `shellcheck` command; Bash syntax validation
still passed, and ShellCheck had reported no findings before the reboot.

### Runs 59-61: eight active CPUs and live graphical boot

Run 59 changed the verified normal-mode graphical configuration to `-smp 8`.
QEMU created eight KVM vCPU threads and the Reims window remained live, but the
guest reported `hw.ncpu: 8` with only one logical, physical, and active CPU.
QMP listed CPU indexes 0 through 7, while CPUs 1-7 remained halted at PC zero.
The guest log exposed the cause:

```text
ApplePSCI - [ERROR] unsupported PSCI version 1.3
ApplePSCI - [ERROR] Failed to obtain PSCI version info.
```

Linux KVM was exposing the host-supported PSCI 1.3 ABI. Ventura's ApplePSCI
accepts PSCI only through 1.1; QEMU's HVF and TCG VMApple paths also expose
1.1. Run 60 verified the diagnosis with the temporary command-line CPU model
`host,kvm-psci-version=1.1`: ApplePSCI started and all eight CPUs became active.
A guest-initiated shutdown also completed normally, confirming the PSCI system
off path.

The permanent fix is in QEMU's VMApple machine initialization: when KVM is
enabled, each CPU's `kvm-psci-version` property is set to `1.1` before
`KVM_ARM_VCPU_INIT`. QEMU rebuilt successfully. The tracked source patch is
17,727 bytes with SHA-256
`fc0e556d6ab5822ed571fab560173ab2ca2a1a3abfc24160e319451652a52b51`.
The resulting `qemu-system-aarch64` is 150,260,984 bytes with SHA-256
`794897c3b5c85361bbb6f2be5fe08e27cdb89f0e1432c25f7cecee5d9fd11255`.

Run 61 is the clean final confirmation. It used the rebuilt VMApple machine
with ordinary `-cpu host -smp 8`, not the temporary command-line override. The
macOS 13.6 build 22G120 guest reported:

```text
hw.ncpu: 8
hw.activecpu: 8
hw.logicalcpu: 8
hw.physicalcpu: 8
```

ApplePSCI 1.1 is registered, matched, and active. Eight concurrent CPU-bound
processes each received 75-82.5 percent CPU during an eight-second sample,
demonstrating parallel guest scheduling. `WindowServer`, `loginwindow`, and
Language Chooser are running in normal multi-user mode. `AppleParavirtGPU` and
`AppleParavirtDisplay` are active, the display is 1920x1080, and Reims continues
to publish fresh frames. The user directly confirmed the live UI on the host
display.

Final evidence is under the ignored directory
`artifacts/vmapple-gui-run61-8cpu-final/`:

```text
guest-proof.txt       2,910 bytes
  sha256 d1eab1b0bb6c11449df35b1e9f0c068fff639b172a0dd89bb73455377545f5e5
qmp-proof.jsonl
  sha256 53f136067e97d16ee408a0d978b6c62dbfc92e1a3f2510de741a23607bc77bdc
screen.ppm            12,493 bytes
  sha256 8d61a9f589304bec5b227efa04115d3cf779a0281be978af9140fe8150c6aa8e
reims-vgpu.log        21,209,710 bytes
  sha256 12f4c992feaa70e2217558f550ef9bd218c479f2c0a7ca3195c5fd1b366de286
```

The launch script now defaults to eight CPUs. Run 61 was intentionally left
running so the successful graphical guest remains available for inspection.

### Run 62: Reims-only presentation

The Reims device owns a native winit/Vulkan window and drives its early-frame
pump from a QEMU host timer. QEMU's GTK display backend was therefore redundant:
it attached a second frontend to the device's fallback `QemuConsole`, but was
not needed for the Reims window or its input path.

Changed the launcher default from `-display gtk,zoom-to-fit=on` to
`-display none` whenever `reims-vgpu-mmio` is selected. `CONSOLE=gtk` remains
available for explicit fallback-console testing; `CONSOLE=reims` is the new
default.

Run 62 booted a fresh reflink of the Run 61 guest with the exact command-line
combination `-machine vmapple,...,gfx-device=reims-vgpu-mmio -smp 8 -display
none`. Reims immediately reported its first 1920x1006 four-image-swapchain
frame. macOS subsequently reported eight active CPUs and a running
WindowServer over SSH. The Reims log continued publishing fresh 1920x1080
non-black frames after userspace started, confirming the standalone window is
the complete presentation path. QEMU PID 21231 was left running for visual and
input inspection.
