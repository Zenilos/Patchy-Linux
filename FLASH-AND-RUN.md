# Linux on the Seeed XIAO ESP32S3 Sense (8 MB)

This is the working reference for the 8 MB / 8 MB-PSRAM XIAO ESP32S3 Sense
image on the `s3-sense` branch. It records what the board needs, what was
missing, and the commands that produced a booting system with WiFi, telnet
and the microSD card working.

The board has **no battery and no ePaper panel**. Everything below is about
the 8 MB profile; the panel work belongs to the ePaper-154 board.

## What works

| function | how |
|---|---|
| Boot | Linux 7.2.4 from the `n8r8/7.2.4` base, XIP kernel + cramfs rootfs in flash |
| Console | USB-Serial/JTAG (`ttyGS3`), login prompt on the USB port |
| Login | `root` / `only-esp32` (`S90rootpasswd` pins the hash) |
| Telnet | enabled by `S90rootpasswd` (`/etc/remote-login` = `telnet`) |
| WiFi | joined at boot from the `cred` partition, or `wifi connect "SSID" "PASS"` |
| microSD | SPI card on SPI2, `mmcblk0p1` mounted as `/home` (FAT32, rw) |
| `/home` without a card | `nofail`; boot and login still work |

## Build

The build runs in its own container so the host needs no toolchain. The
container image is built from `build/Dockerfile` and is named
`linux-esp32s3-reproduce:local`.

```
PROFILE=esp32s3_devkit_c1_8m
BOARD=                      # unset: the 8m profile picks devkit_c1
```

Inside the container (`/work` is a volume, the source tree is
`/work/Linux-on-esp32-S3`):

```sh
cd /work/Linux-on-esp32-S3
PROFILE=esp32s3_devkit_c1_8m bash build/container-build.sh
```

The stages are `toolchain`, `base-rootfs`, `firmware`, `userspace` and
`package`. A finished stage leaves `/work/stages/<name>.done`; the next run
**reuses it silently**. That is useful for an unchanged tree and dangerous
after a kernel config or device-tree change: the build finishes with the old
artifact and the same sha256.

After changing the kernel config, the kernel patches or the DTS, force the
affected stages:

```sh
rm -f /work/stages/base-rootfs.done /work/stages/userspace.done /work/stages/package.done
rm -rf /work/refs/esp32-linux-build/build/build-buildroot-esp32s3_devkit_c1_8m/build/linux-7.2.4
rm -rf /work/Linux-on-esp32-S3/experiments/mmu-poc/out/linux-fork
```

`out/linux-fork` is a copy of buildroot's kernel tree taken only when it does
not exist. If it survives, `build-kernel-reclaim.sh` builds the final XIP
image from the stale copy and the config check reports the change as missing
(`CONFIG_MMC_SPI: seed says y, built has not set`).

Artifacts land in `/work/artifacts`; for this build:

```
linux-esp32s3-xiao-8m-full.bin   sha256 91420c2dfc008671e337403a112e978097ef8c76b020a2c604b0f4e56554a684
```

## Console on USB

The board's UART0 is not wired to anything. The bootargs end with

```
console=ttyS0,115200n8 console=ttyGS3
```

because the **last** `console=` becomes `/dev/console`, and userspace writes
there. With the upstream order (`ttyGS3` first) the board boots, but init
and the login prompt go to the unconnected UART. The swap is in
`09-kernel-xiao-sense-pins.patch`.

## Device tree: the SPI2 pins

The Sense expansion board wires its microSD slot to GPIO21 (CS), GPIO7
(SCK), GPIO8 (MISO) and GPIO9 (MOSI). Only GPIO10-13 carry the FSPI IO MUX
functions the devkit assignment uses, so the signals go through the **GPIO
matrix**, the way `esp32s3-box3.dts` already routes SPI2:

- pads stay at IO MUX function 0 (matrix);
- `gpio_out_mux` selects CS0=110, MOSI=103, SCK=101 on GPIO21/9/7;
- `gpio_in_mux` selects signal 102 (FSPIQ_IN_IDX) from GPIO8 with the
  matrix bit set (`0x88` = `0x80 | 8`).

I2C0 moves from GPIO6/GPIO7 to GPIO5/GPIO6 so GPIO7 is free for the SD
clock. The OLED and the rest of that bus keep working.

The `mmc_spi@0` node itself comes from the platform patch
(`0039-xtensa-esp32-add-platform.patch`); the XIAO patch only changes where
its pins go.

## microSD over SPI

The card is **SPI**, not SDMMC: the SDMMC table in
[`sd-card-n8r8.md`](sd-card-n8r8.md) is the Waveshare ePaper-154 board.
`CONFIG_MMC_DW` is irrelevant here.

Two things were missing and both looked like a dead slot:

1. **`CONFIG_MMC_SPI` was off.** The trimmed 8 MB config kept only the
   SDMMC host, so the `mmc-spi-slot` node had no driver and no `/dev/mmcblk0`
   appeared. The boot still printed `/dev/mmcblk0p1: Can't lookup blockdev`
   from the mount attempt, which reads like a card problem rather than a
   missing driver.
2. **The node had no `spi-max-frequency`.** Even with the driver it would
   probe at 0 Hz.

The fix is in `devkit_c1_8m_linux.config` (`CONFIG_MMC_SPI=y`) and in the
XIAO DTS patch (`spi-max-frequency = <20000000>;`). 20 MHz is the usual
ceiling for this wiring.

A healthy boot shows:

```
mmc_spi spi0.0: ASSUMING 3.2-3.4 V slot power
mmc_spi spi0.0: SD/MMC host mmc0, no WP, no poweroff, cd polling
mmc0: new SDHC card on SPI
mmcblk0: mmc0:0000 SD16G 14.5 GiB
 mmcblk0: p1
FAT-fs (mmcblk0p1): ...
```

and `/home` is mounted read-write:

```
/dev/mmcblk0p1   14.4G   72.2M   14.4G   0% /home
```

The 8 MB partition table has no `home` partition. `build/package-final.py`
writes the blank `cred` partition and the rootfs; the **final** fstab is
rewritten by `experiments/mmu-poc/programs/image-profiles.py` for the 8m
profile, turning the shared `mtd:home` line into:

```
/dev/mmcblk0p1	/home	vfat	nofail	0	0
```

`nofail` is what keeps the boot working with no card. `S05home` and
`home-init` check the mount and skip quietly when it is absent.

## WiFi from the `cred` partition

The image itself carries no network. A plain-text credential can be written
into the 64 KiB `cred` partition at flash time, exactly as for the ePaper
board:

```sh
./flash.sh -p /dev/tty.usbmodem1101 \
    --images build-output/reproduce.s3-sense-sd/artifacts \
    --erase --creds cred.txt
```

`cred.txt` is two lines:

```
ssid=YOUR SSID
psk=YOUR PASSWORD
```

It is ignored by git (it holds the passphrase). `flash.sh --creds` runs
`tools/credential.py`, which fills the partition in a copy of the full image
(the full image covers the whole flash, so the credential cannot be a second
write). With `--parts` the same tool writes `cred.bin` instead.

On boot `S39wifi-cred` reads the partition and writes
`/etc/wpa_supplicant.conf` (mode 600) before the network starts:

```
S39wifi-cred: the WiFi credential from the cred partition is in place
Starting network (background): OK
```

The credential in flash wins over an old `/etc/wpa_supplicant.conf`. Once
the board is up, `wifi connect "SSID" "PASS"` changes the network in
`/etc/wpa_supplicant.conf`; that file is what rejoins on later boots, while
the `cred` partition is the factory/default value restored on a fresh
`/etc`.

`wifi status` currently prints "Not associated." even while the link is up
and an address is assigned: it greps `iw dev espsta0 link` for a string this
driver does not emit. Cosmetic only; `ip addr` and traffic are correct.

## Flash and verify

```sh
PROFILE=esp32s3_devkit_c1_8m \
FULL_IMAGE=linux-esp32s3-xiao-8m-full.bin \
./flash.sh -p /dev/tty.usbmodem1101 \
    --images build-output/reproduce.s3-sense-sd/artifacts \
    --erase --creds cred.txt
```

The full 8 MB image overwrites `/etc` even without `--erase`; `--erase`
also removes any old board data. The SD card is not touched.

Verification used here:

- serial login prompt appears on `/dev/tty.usbmodem1101` at 115200;
- `uname -a` → `Linux buildroot 7.2.4-forkbank ... xtensa GNU/Linux`;
- `ls /dev/mmcblk*` and `df -h /home` (14.4 G, write test passes);
- ping and `telnet 192.168.1.69` (login `root` / `only-esp32`);
- a reboot rejoins WiFi and remounts `/home` without serial input.

## Notes for the next change

- The boot log is quiet; `mmc_spi` lines are only in `dmesg`, not on the
  console.
- The SD card is a **FAT32** card; the board writes `/home/.etc-backup`
  there, so `--parts` flashes keep the network and accounts while `/etc` is
  rewritten.
- The login shell prints `can't change directory to '/home/root'` when no
  card is mounted. It is a warning from `login`, not a failed login.
- GNU patch 2.7.6 rejects a hunk that ends with exactly two lines of
  trailing context. When hand-writing a kernel patch for this tree, give
  every hunk **at least three** trailing context lines. This is why the
  mmc_spi hunk in `09-kernel-xiao-sense-pins.patch` extends past
  `mmc_spi@0 {`.
