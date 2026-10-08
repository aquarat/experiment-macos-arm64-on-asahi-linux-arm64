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

## Memory balloon (macOS guests)

Guest RAM that macOS has touched stays resident on the host until QEMU exits
(a freshly booted 10 GiB Tahoe guest already holds ~6.5 GB). The balloon
gives it back while the guest runs: `BALLOON=1` (`launch-kvm.sh`) adds
`virtio-balloon-pci` with `macos-units=on` (needs the aquarat QEMU fork) and
`vm-job.sh` runs `scripts/balloon-governor.py` next to the job.

### AppleVirtIOBalloon protocol (macOS 26.4)

From the driver's disassembly, confirmed with QEMU traces
(`-trace virtio_balloon_macos_*`, `-msg timestamp=on`):

- Features taken: MUST_TELL_HOST, STATS_VQ, VERSION_1, INDIRECT_DESC,
  EVENT_IDX (never DEFLATE_ON_OOM, free-page hints or reporting). Queues:
  inflate 0, deflate 1, stats 2. A buffer is one array of u32 4 KiB PFNs,
  four consecutive ones per 16 KiB guest page.
- The driver counts surrendered memory itself (P, 4 KiB units) and never
  uses `actual` (it adds the used length / 4, which QEMU reports as 0). On a
  config interrupt and after every completed inflate or deflate buffer it
  runs `N = num_pages; if (N > P) inflate(P, N); if (N < P) deflate(P, N)`.
- Unit mix-up: `inflate` allocates N - P **16 KiB** pages and adds 4 (N - P)
  to P; `deflate` gives back P - N 16 KiB pages. Every request moves 4x.
- The second test reuses the N read before the inflate, so every inflate of
  d pages is immediately followed by a deflate of 3d pages, taken from the
  inflate buffers the device has already completed. It succeeds once that
  set holds 3d pages. This is the "spontaneous" deflate; it has nothing to do
  with memory pressure (the driver has no pressure hook). Trace with plain
  quarter-steps (`macos-hold=off`): after three 256 MiB steps every 65536-PFN
  inflate is followed 0.3-2 ms later by a 196608-PFN deflate, and the
  balloon saw-tooths between ~0.25 and 1.5 GiB without reaching a 6 GiB
  target.
- Each request is limited to (free descriptors) x 4096 of its units, but a
  16 KiB segment of the PFN array holds 1024 of them. With QEMU's 128-entry
  queues a deflate above 2 GiB fails to post and is retried forever (a 5 GiB
  deflate never arrived).
- P grows when a buffer is posted, before the device consumes it; a config
  read in between sees a stale count.
- Guest-side cost: one 16 KiB `IOBufferMemoryDescriptor` per page. Inflate
  allocates ~1.2 GiB/s; giving memory back is bounded by the driver freeing
  them (~1 GiB/s, deflate rounds wait for the previous round's frees).
  The driver also re-runs its handler on stats interrupts (config reads
  every 5 s with `guest-stats-polling-interval=5`). Before the changes below
  it never inflated without stats polling, so the launcher keeps polling on
  (the stats themselves are empty); 1 s instead of 5 s polling does not
  change deflate times.

### QEMU side (`macos-units=on`, fork branch with `macos-hold`)

- `actual` counts the PFNs received (4 KiB units); guest writes are ignored.
- Config reads first consume any posted buffers, so `actual` equals the
  driver's P whenever it compares.
- Inflate: present `actual + min(target - actual, macos-step) / 4`
  (`macos-step`, default 65536 = 256 MiB per round). With `macos-hold=on`
  (default) the device discards the pages at once (`fallocate` punch-hole on
  memfd RAM, `MADV_DONTNEED` on anonymous RAM; contiguous PFN runs in one
  call) but keeps the buffer instead of completing it, so the completed set
  stays empty and the stray 3x deflate always fails; one config interrupt per
  consumed buffer asks for the next round.
- Deflate: complete just enough held buffers (newest first), then present
  `actual - min(completed, 2 GiB) / 4` so the driver gives back exactly those;
  the overshoot (< one round) is inflated again. Nothing to do on the host
  (pages refault when touched).
- Inflate and deflate queues have 1024 entries.

Measured (10 GiB guest, GPU on, memfd RAM): targets 4096, 6144, 3072, 9216,
2048, 10240, 5120, 1536, 7168, 10240 MiB were each reached exactly (no
oscillation, no stray deflates); inflate 6 GiB in 5.2 s, 7 GiB in 7.4 s;
deflate 6 GiB in 4.6 s, 8 GiB in 6.2 s (QEMU's count; the guest finishes
freeing shortly after). Host memory follows: an idle guest squeezed to
1.5 GiB costs 1.7 GB.

Notes on measuring and memfd RAM:
- Punch-holes free memfd memory with shmem THP too: in a test memfd with
  32 MiB folios, punching every other 16 KiB page of 256 MiB released
  exactly 128 MiB (folios split; refaulted holes come back as 16 KiB pages).
  QEMU's memfd guest RAM gets no THP at all, though: its mapping starts
  16 KiB short of a 32 MiB boundary (guard page), `THPeligible: 0` even with
  `shmem_enabled=advise`.
- For memfd RAM, QEMU's `Rss` under-counts (pages stay in the memfd but are
  not mapped in QEMU's page tables); count the memfd's allocated blocks
  (`stat -L -c %b /proc/<pid>/fd/<memfd>`) plus `Pss_Anon`.

### Governor (`scripts/balloon-governor.py`)

One per guest, Python stdlib only, started by `vm-job.sh` after the guest
answers SSH and stopped before shutdown (log: `job-logs/<job>/balloon-governor.log`).

- Guest state: one long-lived `ssh ... exec vm_stat 1` (one line per second,
  no process per sample). `available` = free + speculative + purgeable + the
  file-backed share of the inactive queue. `vm_stat` repeats its header with
  a totals line, which is skipped. Pressure = compressions + swap-outs.
- Balloon size: QMP `query-balloon` on a monitor of its own
  (`<job>.balloon.qmp`, so `vm-run.sh qmp` is never blocked).
- Deflate at once on pressure (compressing/swapping above
  `BALLOON_COMPRESS_RATE`, available below half the margin, or available
  falling by >= 128 MiB a sample, fast enough to cross the margin within two
  samples): by the
  shortfall + 2x the last drop + 2x what was compressed, at least
  `BALLOON_DEFLATE_MIN`; then no inflating for `BALLOON_COOLDOWN`.
- Inflate gently on surplus (available above margin + hysteresis for 3
  quiet samples): half the surplus, at most `BALLOON_INFLATE_STEP` every
  `BALLOON_INFLATE_EVERY` seconds, never below `BALLOON_MIN_GUEST`.
- Re-sends a target the driver has not reached within 10 s (an inflate it
  cannot allocate is dropped); releases the balloon if `vm_stat` is silent
  for `BALLOON_BLIND` seconds.

Tunables (env): `BALLOON_MARGIN` (1536M), `BALLOON_HYSTERESIS` (512M),
`BALLOON_INTERVAL` (1), `BALLOON_MIN_GUEST` (2560M), `BALLOON_MAX`,
`BALLOON_INFLATE_STEP` (512M), `BALLOON_INFLATE_EVERY` (5),
`BALLOON_DEFLATE_MIN` (1G), `BALLOON_COOLDOWN` (60), `BALLOON_COMPRESS_RATE`
(64 pages/s), `BALLOON_BLIND` (30), `BALLOON_DRY_RUN`, `BALLOON_VERBOSE`;
`BALLOON_GOVERNOR=0` disables it in `vm-job.sh`.

### Measurements (10 GiB guest, 4 vCPUs, default tunables)

Host footprint = memfd blocks + `Pss_Anon` (GPU on) or QEMU `Rss`
(`GFX=none`), sampled every 2 s; the host was shared with other VMs, so wall
times vary by about +-15 % between identical runs.

| run | job phases (s) | total | footprint avg / peak |
|---|---|---|---|
| idle 15 min, no balloon | - | - | 8.78 / 10.09 GB |
| idle 15 min, governor | - | - | 4.84 / 6.67 GB |
| build+test+burst, no balloon (2 runs) | build 106, 85; test 154, 173 | 310, 321 s | 9.85, 9.72 / 10.5 GB |
| build+test+burst, governor (2 runs) | build 87, 83; test 108, 170 | 251, 314 s | 8.85, 9.05 / 10.5 GB |
| same, `GFX=none`, no balloon | build 83; test 93 | 221 s | 9.63 / 10.28 GB |
| same, `GFX=none`, governor | build 70; test 94 | 212 s | 8.83 / 10.23 GB |

- Idle: the governor settles in about a minute at ~4.3 GiB guest memory
  (avail ~2 GB). Without it the idle guest grows to 10 GB (a background task
  at ~5 min touches 3.5 GB that never comes back); with it the same event
  cost one 1 GiB deflate and was taken back a minute later.
- Job (xcodegen iOS framework of 150 generated Swift files built for the
  simulator, 40 hostless unit tests on an iPhone simulator, then 6 GiB of
  incompressible allocation): no slowdown measurable; the build and the
  simulator need nearly all 10 GiB, so the governor hands everything back in
  the first minute of the build and the job ends before the cooldown.
- Worst case, a 6 GiB incompressible burst into a squeezed guest (balloon
  5.75 GiB): written in 8.6 s instead of 1.1-2.3 s; the governor reacts on the
  first sample showing compression and the driver returns the 5.75 GiB in
  ~6 s (2 GiB rounds). A larger `BALLOON_MARGIN` buys headroom for bursts.
- Governor CPU: 0.13-0.32 s per job/15 min (0.02-0.06 % of a core) plus
  0.02-0.07 s for its SSH client; the guest side is one `vm_stat` process.
- Stats polling interval 1 s vs 5 s: no difference in deflate time (8 GiB:
  4.3-5.4 s vs 3.1-4.8 s).

Co-tenancy: a governed idle guest leaves ~4-5.5 GB more host memory to its
neighbours than an unballooned one, and a guest that has finished a burst gives the
memory back (memfd 10.0 -> 3.9 GB within two minutes, cooldown included)
instead of holding its high-water mark until QEMU exits. Two governed
guests side by side were not run here (one test VM at a time on a shared
host).

## Audio (macOS guests)

Without a sound device a Tahoe guest has no CoreAudio device at all
(`system_profiler SPAudioDataType` lists none), and playback fails rather
than hangs:

- macOS: `afplay` exits after 0.3 s with `AudioQueueStart failed (-66680)`
  ("Could not find default device"); `AVAudioEngine.start()` throws -10875
  (`IsFormatSampleRateAndChannelCountValid(outputHWFormat)`).
- iOS 26.4.1 simulator (hostless XCTest): `AVAudioSession` activates and
  reports a "Speaker" route at 48 kHz, but `AVAudioEngine`'s output format is
  0 ch / 0 Hz and `start()` throws -10851 at `kAUInitialize`;
  `AVAudioPlayer.play()` returns false, `currentTime` stays 0 and
  `audioPlayerDidFinishPlaying` never arrives (code that waits for it hangs
  until its own timeout); `AudioServicesPlaySystemSound` returns at once but
  its completion never fires ("Can't make UISound Renderer"). No CPU spin.

So a media app's playback tests need a device. Nobody listens, so QEMU's
`none` audiodev (discards output, paces it in real time) is enough;
`AUDIO=virtio|usb|none` in `launch-kvm.sh` adds one (default `virtio`).

### virtio-sound and AppleVirtIOSound

Tahoe (arm64) does ship a virtio sound driver: `AppleVirtIOSound` in
`AppleVirtIO.kext` (`IOVirtIOPrimaryMatch 0x00191af4`) plus the CoreAudio
plug-in `/System/Library/Audio/Plug-Ins/HAL/AppleVirtIOSound.driver`, which
loads on a registered `AppleVirtIOSound` and talks to it through
`AppleVirtIOSoundUserClient`. With stock QEMU `virtio-sound-pci` the driver
matches but stays `!registered`. From `AppleVirtIOSound::start`:

- The Apple vendor-data capability is optional.
  `readAndValidateAppleVendorSoundConfiguration` reads 5 bytes from the first
  Apple vendor capability; when bit 0 of byte 0 is set, byte 4 is published
  as `AVIOSoundDeviceRole`. Without the capability that property is just
  missing.
- It requires `streams > 0`, allocates jacks/streams/chmaps arrays, then
  always sends JACK_INFO, PCM_INFO and CHMAP_INFO (start 0, count = the
  config value, so 0 jacks and 0 chmaps by default) and gives up on any
  status but OK. QEMU answered JACK_INFO and CHMAP_INFO with NOT_SUPP even
  for zero items.

The fork answers an empty query with OK (commit "virtio-snd: answer empty
JACK_INFO and CHMAP_INFO queries"). With that the guest shows "Apple Virtual
Sound Device" (2 ch, 48 kHz, Built-in) as default output. With the default
`streams=2` it is also the default input, and CoreAudio starts the capture
stream together with every playback, so the launcher passes `streams=1`
(output only). A QEMU without the fix gives the same result as no device.

### usb-audio

`usb-audio` on the machine's own xHCI works with any QEMU: AppleUSBAudio and
`usbaudiod` bind and CoreAudio gets an output-only "Audio Output - Disabled"
(QEMU's alternate-setting string) at 48 kHz. Isochronous USB is expensive to
emulate, though (below).

### Behaviour with a device (simulator XCTest)

| | usb | virtio (`streams=1`) |
|---|---|---|
| `AVAudioEngine.start()` | 0.12 s | 0.01 s |
| 1 s tone, schedule to `.dataPlayedBack` | 1.28 s | 1.12 s |
| `AVAudioPlayer`, 1 s WAV, to `didFinishPlaying` | 1.07 s | 1.21 s |
| 20 s looped tone: rendered vs wall | 20.02 / 20.03 s | 20.01 / 20.04 s |

`AudioServicesPlaySystemSoundWithCompletion` returns in < 2 ms with either
device, but its completion arrived late (19-92 s) in these 6 GiB guests,
where the booted simulator was swapping. That was not investigated further.

Once a simulator has played anything, the guest keeps the output stream
running until the simulator shuts down: QEMU traces show one PCM_START at
the first test playback and the matching STOP at `simctl shutdown`, 7
minutes later (usb: the same, with short alternate-setting gaps). For CI
that means the playback cost below applies for the rest of the job, not
just while a test plays.

### Host cost

QEMU process CPU on the host, from `/proc/<pid>/task/*/stat`, as % of one
host core (6 GiB, 4 vCPUs, `GFX=none`, no simulator). "Playing" is a 30 s
`AVAudioEngine` tone from a macOS CLI with `audiomxd` stopped (see below).

| | idle | playing | main thread playing | main-thread wakeups/s playing |
|---|---|---|---|---|
| no device | 9-12 % | - | - | - |
| usb | 10-11 % | 36 % | 4.7 % | ~1250 |
| virtio, 2 streams | 9-14 % | 11.3 % | 1.4 % | ~245 |
| virtio, `streams=1` | 9 % | 9.8 % | 1.1 % | ~255 |

Idle cost does not change with a device. In the guest during playback, usb
costs kernel_task 13 % + `usbaudiod` 6 % + coreaudiod 2 % of a vCPU; virtio
costs coreaudiod 2-3 % and nothing visible in the kernel.

The `none` audiodev's timer (`timer-period`, default 10 ms) only runs while a
stream is active. `-trace audio_timer_*` shows `audio_timer_start` at
PCM_START (or when the USB alternate setting is selected) and
`audio_timer_stop` at the end, with no timer while idle, so no setting is
needed.

Recommendation: `AUDIO=virtio` (the launcher default, `streams=1`) on a QEMU
with the fork fix. It is the cheapest device that macOS accepts: +0.4-2 % of
a host core while streaming against +25 % for usb, with no idle cost. Use
`AUDIO=usb` only with a QEMU that cannot be updated, and `AUDIO=none` for
guests that never play audio.

### The audiomxd loop (no console user)

As soon as a macOS process starts playing (`afplay`, or `AVAudioEngine` from a
CLI), `audiomxd` (MediaExperience) tries to tell Bluetooth audio routing about
the session. Without a console user that fails ("UpdateAudioState failed to
start XPC: kUnexpectedErr (No user logged in)"); it reports "audioaccessoryd
died", re-syncs and fails again, in a tight loop. That is up to ~250,000 log
lines a minute, with `audiomxd` at ~85 %, `configd` at ~43 % (console-user lookups)
and `logd` at ~5-9 % of a vCPU. It continues after playback ends, until
`audiomxd` is killed; the respawned daemon stays quiet until the next
playback. Host QEMU CPU goes to 200-340 %. With no device it never happens,
because playback fails before a session starts.

Playback inside the iOS simulator does not trigger it: after the full XCTest
run (including 20 s of continuous playback) there was one such log line and
`audiomxd` was idle. For simulator-only CI a device is therefore safe. Jobs
that play audio on the macOS side should `sudo killall audiomxd` afterwards,
or the image needs a console session (auto-login, not tried here).

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
