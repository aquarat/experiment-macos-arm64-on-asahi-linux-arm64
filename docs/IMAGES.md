# Golden images: building the macOS guest chain from scratch

How the read-only "golden" guest bundles used by `scripts/vm-job.sh` and the
runner orchestrators are produced, layer by layer, from an Apple restore image.
Each layer is a script in `images/` run inside a guest booted from the
previous bundle, or a host-side procedure where a guest cannot do the work.
Background and failure analysis are in [NOTES.md](NOTES.md).

Golden images contain an installed copy of macOS, the VM identity
(`vm.json`) and your SSH public keys. Build them yourself; never publish them.

## The chain

| Step | How | Bundle (`~/vm-artifacts/…`) | Adds |
| --- | --- | --- | --- |
| 00 | macOS host: `images/host/macos-restore.sh tahoe` | `tahoe-26.4-25E246-restore` | pristine restore, 160 GiB disk, version-1 hardware model |
| 05 | Linux host: `images/host/create-account.sh` | `tahoe-26.4-25E246-v0` | account, sshd, keys, sudo (KVM single-user) |
| 10 | `images/10-headless-clt.sh` | `tahoe-26.4-25E246-v1` | no sleep, Spotlight off, NTP, time zone, Command Line Tools 26.6 |
| 20 | `images/20-actions-runner.sh` | `-v2` | GitHub Actions runner 2.338.0 in `~/actions-runner` |
| 30 | `images/30-forgejo-runner-node.sh` (+ `images/host/build-forgejo-runner-darwin.sh`) | `-v4` | forgejo-runner v13.2.0 (darwin-arm64), Node v24.21.0 |
| 40 | `images/40-lan-service.sh` (bake with a tap NIC) | `-v6` | DHCP service `LAN` on `en1` |
| 45 | `images/45-avp-rtc.sh` (under the `avp,rtc` QEMU) | `-v7` | NVRAM RTC offset |
| 50 | `scripts/bake-xcode.sh` with a user-supplied `.xip` | `-v9` | Xcode 26.4.1 (17E202) |
| 55 | `images/55-ios-simulator.sh` | `-v10` | iOS 26.4.1 simulator runtime (23E254a) |
| 60 | `images/60-ci-tools.sh` | `-v11` | CI toolchain (below) |

Gaps in the numbering are discarded experiments: v3 (timed state reset) and
v5 (`launchctl disable` timed) did not help the boot stall; v8 (software
update settings) had no effect on 26.4. In the reference chain v0 and v1 were
one bundle (layer 10 ran in the same session as the account creation).

Layer 60, `images/60-ci-tools.sh`: Homebrew (installer pinned by commit),
JDK 21, actionlint, shellcheck, xcodegen, xcbeautify, SwiftLint, Carthage,
CocoaPods, fastlane; versions recorded in the image.

## Conventions

- **Name**: `<os>-<version>-<build>-vN`, e.g. `tahoe-26.4-25E246-v7`. N only
  grows; a rebuilt layer gets a new N, never the old name.
- **Bundle layout** (what `scripts/vm-run.sh` expects):

  ```text
  <bundle>/guest/disk.img          sparse raw root disk
  <bundle>/guest/aux.img.trimmed   32 MiB AUX/NVRAM payload (authoritative after any KVM boot)
  <bundle>/guest/vm.json           macosvm config; machineId holds the ECID (QEMU uuid)
  <bundle>/extras/                 AVPBooter copy, provenance (copied forward by every bake)
  <bundle>/README.txt              one line per layer, appended by every bake
  <bundle>/MANIFEST.sha256         sha256 of guest/*
  ```

  Inside the guest, `/etc/vmapple-image-version` has one line per layer
  (`bake-golden.sh` appends `+ <note>`).
- **Read-only, reflinked**: bakes and jobs boot a `cp --reflink=always` clone
  in `artifacts/runs/`, and promotion reflinks the clone's files into the new
  bundle and makes them read-only (`chmod a-w`). Keep `~/vm-artifacts` and the
  checkout on the **same btrfs** (or XFS) filesystem; on others `cp
  --reflink=always` fails. Layers then share unchanged blocks: v1 is ~22 GB
  allocated, v7 ~25 GB, v9 ~31 GB.
- **Guest user** (`GUEST_USER`): the admin account created in step 05, with
  passwordless sudo and zsh. `scripts/bake-golden.sh`, `bake-xcode.sh` and
  `vm-job.sh` log in as `aquarat`; use that name or change those scripts.
- **Keys**: a dedicated runner key pair on the Linux host, made once:

  ```sh
  ssh-keygen -t ed25519 -N '' -C vmapple-runner -f ~/.ssh/vmapple_runner
  ```

  Its public half (plus any operator key) goes into the account at step 05;
  the private half is `RUNNER_KEY` (default `~/.ssh/vmapple_runner`) for
  bakes and jobs and must be present on every host that runs the images.
  Every image carries these public keys and the account password, so treat
  bundles as secrets. Guest SSH is forwarded to `127.0.0.1` only
  (`SSH_BIND`), but on a bridged NIC (layer 40) the guest's sshd is on your
  LAN: use a strong account password.
- **Verify a copy**: `(cd <bundle> && sha256sum -c --quiet MANIFEST.sha256)`.
- **Move between hosts** (sparse-preserving, ~25 GB in ~11 min on GbE):

  ```sh
  cd ~/vm-artifacts && tar -cS <bundle> | zstd -1 -T4 -q |
      ssh <host> 'cd ~/vm-artifacts && zstd -d -q | tar -xS && cd <bundle> && sha256sum -c --quiet MANIFEST.sha256 && echo VERIFIED'
  ```

  Bundles are host-independent; AVPBooter and the runner key go along.
- **Delete**: `chmod -R u+w <bundle> && rm -rf <bundle>`.

## Prerequisites

**Linux host** (where the images are baked and run):

- Apple Silicon running Fedora Asahi Remix 44 (tested: M1 Max t6001, M1 Ultra
  t6002), with KVM and the patched host kernel:
  `scripts/build-host-kernel.sh <base .src.rpm> vmapple2` (see NOTES.md, Host
  kernel). `dmesg` must show `ACTLR virtualization (IMPDEF, Apple)`.
- QEMU from `scripts/build-qemu.sh` (Fedora packages listed in NOTES.md). This
  QEMU has the `avp,rtc` clock, the BDIF disk-size and PAC-HVC fixes, so every
  bake runs under it. Check: `cat build/qemu-fleet/BUILD-MANIFEST`.
- `gdb`, `socat`, `python3`, `zstd`; btrfs for `~/vm-artifacts` and the checkout.
- Disk: ~25 GB per base bundle, +10 GB for Xcode, +9 GB for the iOS runtime,
  plus room for one running clone. 16 GiB RAM for a bake guest.
- Wired Ethernet for layer 55 (and preferably all layers): see pitfalls.

**A native macOS host** (Apple Silicon, any macOS recent enough to run
Virtualization.framework's restore; the reference host ran macOS 26.4 25E246).
An Asahi machine's own macOS install works: from Linux,
`sudo asahi-bless --set-boot-macos --next -y && sudo systemctl reboot` boots
macOS once; the next reboot returns to Linux. It needs the Command Line Tools
(`xcode-select --install`), ~180 GB free for a Tahoe restore (sparse) plus the
~18 GB IPSW, and `sudo` is not required.

**AVPBooter** (the VM boot ROM, Apple-provided, never commit it): on the macOS
host it is
`/System/Library/Frameworks/Virtualization.framework/Resources/AVPBooter.vmapple2.bin`;
`macos-restore.sh` copies it into the bundle's `extras/` named after its
version (`strings … | grep mBoot-`). Put it where `scripts/vm-run.sh` looks:

```sh
mkdir -p artifacts/firmware
cp ~/vm-artifacts/tahoe-26.4-25E246-restore/extras/AVPBooter.vmapple2.mBoot-18000.101.7.bin artifacts/firmware/
# or: AVPBOOTER=<path> for any vm-run.sh / bake / job invocation
```

The reference booter is `mBoot-18000.101.7` (304,352 bytes, sha256
`1e41405ec4ac25427782f0e5b3a70f568d110eaf891800614a5f86b4fda7e9bd`), from
macOS 26.4. A different booter version may need the GDB injector's constants
rechecked (only relevant with `INJECT=1`, i.e. step 05).

**Restore images** (Apple CDN; `macos-restore.sh` downloads and checks them):

| OS | File | SHA-1 |
| --- | --- | --- |
| macOS 26.4 (25E246) | `UniversalMac_26.4_25E246_Restore.ipsw` from `https://updates.cdn-apple.com/2026WinterFCS/fullrestores/122-00766/062A6121-2ABE-45D7-BCB1-72B666B6D2C2/` | `177baf85518c6e9cebf83990e11e59259b5c97dd` |
| macOS 13.6 (22G120) | `UniversalMac_13.6_22G120_Restore.ipsw` (12,893,555,341 bytes) from `https://updates.cdn-apple.com/2023FallFCS/fullrestores/042-55833/C0830847-A2F8-458F-B680-967991820931/` | `a1675f2c8412122a5e796981571b0269a966708e` |

Restores need Apple's personalization server (network on the macOS host).

**Xcode** (layer 50): `Xcode_26.4.1_Apple_silicon.xip` from
developer.apple.com/download/all (needs an Apple ID), 2,311,684,752 bytes,
sha256 `c9d2e3afe83fd55f53bb35ef259741351f3327d1f11a3f4a5fb90d5c238db4a2`.

## Step 00: restore on macOS (procedure)

On the macOS host, in a checkout of this repository:

```sh
images/host/macos-restore.sh tahoe          # WORKDIR defaults to ~/vmwork
```

It builds `s-u/macosvm` at `c21fd7414bab38b0a2474b351b90378bdef98325` with
`patches/macosvm-hwmodel-override.patch`, downloads and SHA-1-checks the IPSW,
then runs:

```sh
echo y | MACOSVM_HWMODEL_B64=<version-1 descriptor> GUEST_DIR=~/vmwork/tahoe-26.4-25E246-restore/guest \
    DISK_SIZE=160g CPUS=8 RAM=16g GUEST_MAC=52:54:00:76:61:71 scripts/provision-on-macos.sh <ipsw>
```

(`macosvm --disk disk.img,size=160g --aux aux.img --restore <ipsw> --net nat
… vm.json`, then `dd if=aux.img of=aux.img.trimmed bs=16384 skip=1`.) A
Ventura restore took 3 min 40 s. Copy the bundle to the Linux host, keeping the
disk sparse, and make it read-only:

```sh
# on the Linux host
ssh <mac> 'cd ~/vmwork && tar --format pax -cf - tahoe-26.4-25E246-restore' | (cd ~/vm-artifacts && tar -xSf -)
cd ~/vm-artifacts/tahoe-26.4-25E246-restore && sha256sum guest/* > MANIFEST.sha256 && chmod a-w guest/*
```

Pitfalls:

- **Tahoe needs the version-1 hardware model.** With the 26.4 restore image's
  own configuration (a `DataRepresentationVersion 2` descriptor) VZ fails at
  once with `VZErrorDomain -9 … Failed to get current host key`. The script
  forces Ventura's descriptor (`DataRepresentationVersion 1, PlatformVersion
  2, MinimumSupportedOS 13.0.0`), which restores 26.4 fine. It is the
  `hardwareModel` field of any Ventura `vm.json`, so it can be checked with
  `python3 -c 'import json,base64,plistlib,sys;print(plistlib.loads(base64.b64decode(json.load(open(sys.argv[1]))["hardwareModel"])))' vm.json`.
- **Disk size is fixed at restore.** 160 GiB leaves ~134 GiB free in Tahoe.
  Sizes other than 64 GiB need the BDIF disk-size fix (in `build-qemu.sh`'s
  QEMU).
- The restore needs no GUI login; it runs fine over SSH. FileVault on the
  macOS host is irrelevant.
- **Do not boot a Tahoe bundle under VZ afterwards.** Every macOS-side boot
  rewrites the AUX payload; if you do, regenerate `aux.img.trimmed` from
  `aux.img` (the `dd` above) before copying.
- A fresh 26.4 guest's System and Data volumes are keystore-encrypted, so
  `scripts/macos-preseed-guest.sh` (offline account creation) cannot write the
  Data volume. Hence step 05.

## Step 05: account from a single-user boot (Linux host)

```sh
cat ~/.ssh/vmapple_runner.pub ~/.ssh/id_ed25519.pub > /tmp/guest-keys     # runner key + operator key
read -rs GUEST_PASSWORD && export GUEST_PASSWORD
GUEST_USER=aquarat images/host/create-account.sh \
    ~/vm-artifacts/tahoe-26.4-25E246-restore ~/vm-artifacts/tahoe-26.4-25E246-v0 /tmp/guest-keys
```

What it does (the commands are typed into the serial console with
`scripts/serial-shell.py`, each checked for exit status 0):

1. Boots a clone with `INJECT=1 XNU_BOOT_ARGS="-s -v serial=11 debug=0x14c"`
   (boot-args go in through the GDB hand-off, so `gdb` is needed here, unlike
   in every later step) and the serial port on a Unix socket:
   `SERIAL=chardev:ser0 QEMU_EXTRA_ARGS="-chardev socket,id=ser0,path=<sock>,server=on,wait=off,logfile=…"`.
   It waits for `-sh-3.2#` (1–3 min).
2. `/System/Library/Filesystems/apfs.fs/Contents/Resources/apfs_boot_util 1`,
   then `… 2`: unlocks and mounts the encrypted Data volume.
3. `launchctl bootstrap system /System/Library/LaunchDaemons/com.apple.opendirectoryd.plist`;
   then `dscl . -create /Users/<user>` with `UniqueID 501`, `PrimaryGroupID 20`,
   `UserShell /bin/zsh`, `RealName`, `NFSHomeDirectory /Users/<user>`;
   `dseditgroup -o edit -a <user> -t user admin`; `dscl . -passwd /Users/<user> '<pw>'`.
   (`dscl -f <node> localonly …` fails here with eDSUnknownNodeName.)
4. `/Users/<user>/.ssh/authorized_keys` (700/600, owner 501:20),
   `/private/var/db/.AppleSetupDone`, `/private/etc/sudoers.d/<user>`
   (`<user> ALL=(ALL) NOPASSWD: ALL`, mode 440),
   `/private/etc/vmapple-image-version`.
5. Remote Login: `PlistBuddy -c 'Add :com.openssh.sshd bool false'
   /private/var/db/com.apple.xpc.launchd/disabled.plist`.
6. `sync; reboot` (QEMU runs with `-no-reboot`, so it exits), then promotes
   the clone like `bake-golden.sh` does. The password is overwritten in the
   console log.

On failure the guest is left running for inspection; stop it with
`scripts/vm-run.sh quit <run>` and remove `artifacts/runs/<run>`. The first
normal boot (layer 10) answers SSH after ~20 s.

## Guest layers (Linux host)

Every guest layer runs the same way: `bake-golden.sh` boots a clone of the
source bundle (`INJECT=0`, 8 vCPU / 16 GiB, retrying stalled boots up to 3
times), pipes the script to `bash -s` over SSH as the guest user, appends the
note to `/etc/vmapple-image-version`, shuts down, and promotes.

```sh
G=~/vm-artifacts
scripts/bake-golden.sh $G/<src> $G/<dst> "<note>" "bash -s" < images/NN-name.sh
# script variables: "env VAR=value bash -s" instead of "bash -s"
```

Each script prints `layer NN complete` as its last line; if that line is
missing from the bake output, the layer did not finish (see Pitfalls).
If the script fails, `bake-golden.sh` stops before the shutdown: the guest is
still running as `bake-<dst>-<pid>`. Quit it with `scripts/vm-run.sh quit
bake-<dst>-<pid>` and delete `artifacts/runs/bake-<dst>-<pid>`; nothing is
promoted. `GFX=none` (no paravirtual GPU) is fine for every bake and saves
the ~80 % of a core that WindowServer burns on llvmpipe.

Verify any layer with a throwaway job:

```sh
GOLDEN=$G/<bundle> scripts/vm-job.sh 'cat /etc/vmapple-image-version; <checks below>'
```

### 10: headless settings, clock, Command Line Tools → v1

```sh
scripts/bake-golden.sh $G/tahoe-26.4-25E246-v0 $G/tahoe-26.4-25E246-v1 \
    "headless settings, CLT for Xcode 26.6, TZ $GUEST_TZ" "bash -s" < images/10-headless-clt.sh
```

`pmset -a sleep 0 displaysleep 0 disksleep 0 standby 0 powernap 0`,
`mdutil -a -i off`, screen saver idle 0, the software-update preference keys,
`systemsetup -setusingnetworktime on`, `sntp -sS time.apple.com`,
`systemsetup -settimezone` (`GUEST_TZ`), and the CLT through
`softwareupdate -i "<label>"` after touching
`/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress`. ~4 min (CLT
3 min 16 s over slirp; no Apple ID). Apple offers only the current CLT for an
OS, so `CLT_VERSION` (26.6) is an assertion; use `env CLT_VERSION=any` to take
whatever is offered. Check: `pmset -g | grep -w sleep; mdutil -s
/System/Volumes/Data; sudo systemsetup -gettimezone; clang --version`
(Apple clang 21.0.0, Swift 6.3.3 in the reference).

Not achievable from inside a 26.4 guest: turning off automatic update checks
(`softwareupdate --schedule off` is a no-op, the preference keys are ignored;
needs a configuration profile), and disabling XProtect (SIP-protected; its
cost is small).

### 20: GitHub Actions runner → v2

```sh
scripts/bake-golden.sh $G/tahoe-26.4-25E246-v1 $G/tahoe-26.4-25E246-v2 \
    "actions-runner 2.338.0 in ~/actions-runner" "bash -s" < images/20-actions-runner.sh
```

Downloads `actions-runner-osx-arm64-2.338.0.tar.gz`, checks the published
sha256, unpacks to `~/actions-runner`; not configured (the orchestrator
creates a JIT config per job). 2 min 22 s. Check:
`~/actions-runner/config.sh --version` → `2.338.0`.

### 30: forgejo-runner and Node → v4

forgejo-runner publishes no macOS binary; cross-compile it on the Linux host
and serve it to the guest over slirp (host `127.0.0.1` = guest `10.0.2.2`):

```sh
images/host/build-forgejo-runner-darwin.sh        # GOOS=darwin GOARCH=arm64 CGO_ENABLED=0 go build -trimpath
                                                  #   -ldflags "-s -w -X …/runner/v13/internal/pkg/ver.version=v13.2.0"
python3 -m http.server -b 127.0.0.1 8000 -d build/forgejo-runner & srv=$!
scripts/bake-golden.sh $G/tahoe-26.4-25E246-v2 $G/tahoe-26.4-25E246-v4 \
    "forgejo-runner v13.2.0 (darwin-arm64 build) in ~/forgejo-runner, Node v24.21.0 in ~/node on PATH via ~/.zshenv" \
    "env FORGEJO_RUNNER_SHA256=$(cut -d' ' -f1 build/forgejo-runner/*.sha256) bash -s" < images/30-forgejo-runner-node.sh
kill $srv
```

The build clones tag `v13.2.0` (commit `df6b843f…`). With go1.26.8 the binary
is byte-identical to the reference (`64cbd7b9…2d44`); other Go releases give
a different hash, which is why the bake passes the hash of your own build.
Node `node-v24.21.0-darwin-arm64.tar.xz` is checked against nodejs.org's
`SHASUMS256.txt` (pin `NODE_SHA256` to avoid trusting the same server twice),
unpacked into `~/node`, and `export PATH=$HOME/node/bin:$PATH` goes into
`~/.zshenv`, the only file non-interactive zsh (every SSH command, hence the
runner) reads. JavaScript actions such as `actions/checkout` need it in host
mode. Check: `~/forgejo-runner/forgejo-runner --version; node --version`.

### 40: network service for a bridged NIC → v6

```sh
sudo scripts/host-net-setup.sh test-up              # isolated test bridge + DHCP, or bridge to the LAN:
# sudo scripts/host-net-setup.sh taps br0 1
TAP_IF=vmtap1 TAP_MAC=52:54:00:76:62:01 scripts/bake-golden.sh $G/tahoe-26.4-25E246-v4 $G/tahoe-26.4-25E246-v6 \
    "network service LAN (DHCP) on en1 for an optional bridged tap NIC" "bash -s" < images/40-lan-service.sh
```

`networksetup -createnetworkservice LAN en1; networksetup -setdhcp LAN`. The
guest only has `en1` while a second NIC is attached, so the bake needs the
tap; without the service macOS never sends DHCP on it. Jobs without a tap are
unaffected. Check (with `TAP_IF` set): `ipconfig getifaddr en1`.

### 45: RTC offset under `avp,rtc` → v7

```sh
scripts/bake-golden.sh $G/tahoe-26.4-25E246-v6 $G/tahoe-26.4-25E246-v7 \
    "baked under QEMU with avp,rtc: NVRAM rtc-offset present, so timed trusts the RTC" "bash -s" < images/45-avp-rtc.sh
```

Just a boot, 25 s wait and clean shutdown. Images baked under a PL031-only
QEMU carry no `com.apple.System.rtc-offset` in NVRAM; timed then logs "RTC
reset likely", sometimes adopts the image's last shutdown time, and those
boots stall (9–15 % before, ~4.5 % after). The reference v1–v6 were baked
before QEMU had `avp,rtc`; on a from-scratch chain with `build-qemu.sh`'s
QEMU every bake already writes the offset and this layer only checks it.
Check: `sysctl kern.monotoniclock_offset_usecs` exists (small negative value),
and `sudo log show --last boot --predicate 'process == "timed"' | grep -c
"RTC reset likely"` is 0.

### 50: Xcode → v9

```sh
sha256sum Xcode_26.4.1_Apple_silicon.xip     # c9d2e3afe83fd55f53bb35ef259741351f3327d1f11a3f4a5fb90d5c238db4a2
GFX=none CPUS=8 RAM=16G scripts/bake-xcode.sh $G/tahoe-26.4-25E246-v7 $G/tahoe-26.4-25E246-v9 \
    ~/Downloads/Xcode_26.4.1_Apple_silicon.xip
```

Copies the `.xip` in (scp), `xip --expand`, moves it to `/Applications`,
`xcode-select -s`, `xcodebuild -license accept`, `xcodebuild -runFirstLaunch`,
appends `+ Xcode 26.4.1 Build version 17E202` to the image record, shuts down,
promotes; its README line records the `.xip` hash. ~1.5 h: `xip --expand` is
latency-bound in the guest (~180 file operations/s, <1 % CPU, Spotlight and
XProtect scanning alongside). The guest needs ~3× the `.xip` size free.
Check: `xcodebuild -version` → `Xcode 26.4.1`, `Build version 17E202`.

`bake-xcode.sh --ios-platform` would add the simulator in the same run; the
reference v9 was baked without it (the download crawled on a Wi-Fi host) and
the platform was added as layer 55. Unlike `bake-golden.sh`, `bake-xcode.sh`
does not retry a stalled boot; rerun it.

### 55: iOS simulator platform → v10

```sh
GFX=none scripts/bake-golden.sh $G/tahoe-26.4-25E246-v9 $G/tahoe-26.4-25E246-v10 \
    "v9 + iOS 26.4.1 simulator platform (xcodebuild -downloadPlatform iOS)" "bash -s" < images/55-ios-simulator.sh
```

Warms CoreSimulatorService (`xcrun simctl list runtimes`), then
`xcodebuild -downloadPlatform iOS` up to 3 times 30 s apart, and appends the
runtime to the image record. The runtime is whatever matches the installed
Xcode (here iOS 26.4.1, 23E254a, an 8.46 GB MobileAsset from
`updates.cdn-apple.com`); Apple does not offer a checksum to pin. ~10 min on a
wired host. Check: `xcrun simctl list runtimes` → `iOS 26.4 (26.4.1 - 23E254a)`;
a smoke test: `xcrun simctl boot "iPhone 17"` (74 s on first boot).

Run simulators with `GFX=none`: with the paravirtual GPU, booting a simulator
aborts QEMU on the host (llvmpipe cannot compile an FP16 fragment shader).

### 60: CI toolchain → v11

```sh
scripts/bake-golden.sh ~/vm-artifacts/tahoe-26.4-25E246-v10 ~/vm-artifacts/tahoe-26.4-25E246-v11 \
    "+ CI tools (images/60-ci-tools.sh): Homebrew, JDK 21, actionlint, shellcheck, xcodegen, xcbeautify, SwiftLint, Carthage, CocoaPods, fastlane" \
    "bash -s" < images/60-ci-tools.sh
```

About 20 minutes on wired Ethernet (Homebrew bottles). The script installs
Homebrew with its installer pinned to a commit (`BREW_INSTALL_REV`), then
the formulae; links the JDK into `/Library/Java/JavaVirtualMachines`; and
appends to `~/.zshenv` (the only file non-interactive SSH shells, and thus
the runner, read): `brew shellenv`, `HOMEBREW_NO_AUTO_UPDATE=1`, `JAVA_HOME`
and a UTF-8 locale (CocoaPods and fastlane need one). Homebrew formulae
cannot be pinned to versions, so the layer records what it installed in
`~/ci-tools-versions.txt` and `/etc/vmapple-image-version`; rebuilding later
gives newer tool versions. Reference build (2026-10): OpenJDK 21.0.12,
actionlint 1.7.12, shellcheck 0.11.0, xcodegen 2.46.0, xcbeautify 3.2.1,
SwiftLint 0.65.1, Carthage 0.40.0, CocoaPods 1.17.0, fastlane 2.240.1,
Homebrew 7.0.8.

Verify: `scripts/vm-job.sh 'java -version; pod --version; cat ~/ci-tools-versions.txt'`
with `GOLDEN` set to the new bundle; the bake log must end with
`layer 60-ci-tools complete` before the shutdown.

Project-specific toolchains (a GraalVM pinned by a project, Gradle and
Kotlin/Native downloads) are not baked in: `actions/cache` against the
runner cache below keeps them across jobs after the first run.

## Runner cache

Throwaway guests lose `actions/cache` contents with every job. A persistent
`forgejo-runner cache-server` on the Linux host
(`systemd/vmapple-runner-cache.service`, listening on the host's loopback)
is reached from guests at `http://10.0.2.2:<port>/`, so caches survive across
guests. Installation steps are in the unit file's header; in short:

1. Install the forgejo-runner Linux binary (same version as in the guests;
   verify the release's `.sha256`) as `/usr/local/bin/forgejo-runner`
   (`restorecon` it on SELinux hosts).
2. Create the secret (`openssl rand -hex 32` into
   `/etc/vmapple-runner/cache-secret`, mode 600) and install
   `systemd/vmapple-runner-cache.yaml` as `/etc/vmapple-runner/cache-server.yaml`.
3. Enable `systemd/vmapple-runner-cache.service`. It runs as a dynamic user;
   config and secret reach it as systemd credentials (the directory stays
   root-only). The server binds every interface whatever `host:` says, so
   the unit restricts it to loopback with `IPAddressAllow=localhost`.
4. Add `FORGEJO_CACHE_SERVER=http://10.0.2.2:4100/` and
   `FORGEJO_CACHE_SECRET=<secret>` to the runner's EnvironmentFile.
   `forgejo-ephemeral-runner.sh` then writes a runner config in each guest
   (`cache.external_server` + `secret`), and the job's cache proxy relays to
   the host.

Linux jobs (e.g. a web client's `ubuntu-latest` job) need no VM:
`systemd/forgejo-runner-docker.service` runs a forgejo-runner daemon on the
same host with the Docker backend (each job in a fresh `node:24-bookworm`
container) and the same cache server. Its service user is in the `docker`
group, which is root-equivalent on the host.

## Pitfalls (all layers)

- **`bash -s` and stdin.** A layer script reaches the guest on stdin and
  bash reads it incrementally, so a command inside it that reads stdin (brew,
  installers, `curl … | sh`, a sudo prompt) swallows the rest of the script,
  and bash exits 0: the bake "succeeds" with half a layer. Every
  `images/NN-*.sh` therefore wraps its body in `main() { set -euo pipefail;
  …; echo "layer NN complete"; }` and ends with `main "$@" < /dev/null`, so
  bash has read the whole file before anything runs and nothing can consume
  it. Write new layers the same way, and check the bake log for the
  `layer NN complete` line.
- **Bake on wired Ethernet.** slirp passes the host's link speed through
  (~25 MB/s for the iOS runtime on GbE) but delivered ~330 KiB/s on a host on
  Wi-Fi, which turns the 8.5 GB simulator runtime into hours.
- **Early-boot stall.** ~4–5 % of macOS 26 boots never reach SSH (idle guest,
  see NOTES.md). `bake-golden.sh` retries from a fresh clone (120 s timeout,
  3 attempts); `bake-xcode.sh` and `create-account.sh` do not.
- **CoreSimulatorService** takes ~30 s to start on first use; until then
  `-downloadPlatform` fails with "Unable to connect to simulator".
- **Clean shutdown only.** Bundles are promoted only after the guest powers
  off by itself (`shutdown -h now`); never copy a running or killed guest.
  Disks run with `cache=unsafe` (`DISK_CACHE`), which is safe for that reason.
- **Do not reset or disable `timed` in an image**: deleting
  `/var/db/timed/com.apple.timed.plist` (rewritten at shutdown) and
  `launchctl disable system/com.apple.timed` (does not survive a reboot) were
  both tried (v3, v5) and did nothing.
- **Avoid** QMP `x-query-virtio-status` / HMP `info virtio-status` on these
  guests (crash / hang).
- `vm.json`'s `machineId` is the VM identity (ECID). Every bundle in a chain
  shares it; restore a new bundle for a distinct identity.

## Ventura 13.6 chain (brief)

The first chain, `ventura-13.6-22G120-v2`, is built differently because
Ventura's Data volume is not keystore-encrypted and its Setup Assistant was
completed interactively:

1. `images/host/macos-restore.sh ventura` (64 GiB disk, default hardware
   model).
2. On the macOS host, boot it with a window (`macosvm -g vm.json` from the
   bundle's `guest/` directory, in a logged-in session) and complete Setup
   Assistant: create `GUEST_USER`, Remote Login on, FileVault off. Then, over
   SSH to the guest: add the runner and operator keys to
   `~/.ssh/authorized_keys`, `echo '<user> ALL=(ALL) NOPASSWD: ALL' | sudo tee
   /etc/sudoers.d/<user>`, and run the settings part of
   `images/10-headless-clt.sh` (the Ventura reference also had `pmset
   autorestart 0` and `softwareupdate --schedule off`, which work there).
   Shut down, then regenerate `aux.img.trimmed` (`dd if=aux.img
   of=aux.img.trimmed bs=16384 skip=1`) because the VZ boots changed AUX.
   Untested alternative: `sudo scripts/macos-preseed-guest.sh` on the
   never-booted disk.
3. Copy to Linux as above; that bundle is v1.
4. v2: Command Line Tools for Xcode 14.3 (2 min 53 s) and the image record:
   `scripts/bake-golden.sh … "bash -s" < images/10-headless-clt.sh` with
   `env CLT_VERSION=14.3 bash -s` (or `any`). Ventura has no early-boot stall
   and needs no `avp,rtc` re-bake; boots reach SSH in 9–10 s.
