# SD card support on the ESP32-S3 N8R8 boards

This is the reference for the microSD slot on the ESP32-S3 boards with 8 MB
flash and 8 MB PSRAM (the "N8R8" part): the Waveshare ESP32-S3-ePaper-1.54
and the Seeed XIAO ESP32S3 Sense.

It records what the slot needs, what was wrong, and what the goals are for
the next kernel.

## The hardware

The slot is **1-line SDMMC** -- clock, command and one data line, and
**no chip select**:

| function | pin |
|---|---|
| SD_CLK | 39 (MTCK) |
| SD_D0 | 40 (MTDO) |
| SD_CMD | 41 (MTDI) |

Because there is no chip select, the card cannot be driven in SPI mode:
SPI needs CS. The controller is the Espressif SDMMC block, a DesignWare
`dw_mmc` core fused with an Espressif clock generator, at `0x60028000`.

The SDMMC signals reach the pads through the **GPIO matrix**, not through a
fixed IO MUX function.

## What was broken, and why

The card was never detected. `dw_mmc` reported:

```
mmc0: Failed to initialize a non-removable card
```

and there was no `/dev/mmcblk0` behind it, so `/home` stayed absent and
every attempt to use the card failed silently.

The cause was in the device tree, and it is a trap worth writing down.

**Pads 39, 40 and 41 are the ESP32-S3's JTAG pads** (MTCK, MTDO, MTDI).
Their IO MUX function 0 is the **JTAG** function, not GPIO. Function 1 is
the GPIO function. ESP-IDF's own table says so:

```
FUNC_MTCK_GPIO39 = 1      FUNC_MTCK_MTCK = 0
FUNC_MTDO_GPIO40 = 1      FUNC_MTDO_MTDO = 0
FUNC_MTDI_GPIO41 = 1      FUNC_MTDI_MTDI = 0
```

The device tree asked for function 0. Since SDMMC reaches these pads
through the GPIO matrix, the matrix output had nowhere to go: the SDMMC
clock, CMD and D0 never reached the wires, and the card never answered.
The one-line fix is to ask for function 1:

```
PIN(39) (FUN_SEL(1) | FUN_DRV_20MA)
PIN(40) (FUN_SEL(1) | FUN_DRV_20MA | FUN_IE | FUN_WPU)
PIN(41) (FUN_SEL(1) | FUN_DRV_20MA | FUN_IE | FUN_WPU)
```

The general lesson: **on this SoC, a pad that is a JTAG pad needs
function 1 to be used as GPIO.** The other pins' function 0 is already
GPIO, which is why the rest of the board works unchanged.

## The driver

`11-kernel-esp32s3-sdmmc-driver.patch` adds the `dw_mmc` glue for the
fused controller. Four things in the stock driver do not fit it:

1. **PIO only.** The DesignWare IDMAC engine in the fused core is not
   driven by the bits `dw_mmc` programs: Espressif reused CTRL bit 24 (the
   DW "use internal DMA" bit) for open-drain select and expects
   CTRL.dma_enable (bit 5) instead. The host is forced to PIO, which
   transfers through the CPU FIFO path.

2. **The first-stage clock generator.** `dw_mmc` programs only the DW
   CLKDIV (second stage) divider, but there is a generator in front of
   it. The register is at offset `0x800` (`SDMMC_CLOCK`), and it is
   programmed the way ESP-IDF's `sdmmc_host_set_clk_div()` does: the
   160 MHz PLL with `div_factor_l = div_factor_n = div-1`,
   `div_factor_h = div/2-1`, `phase_dout = 1` (a 90 degree hold, which
   the panel-style timing needs), `phase_din = phase_core = 0`. With
   `div = 4` the output is 40 MHz, matching the 40 MHz ciu clock rate that
   `dw_mmc` derives `bus_hz` from. A CTRL reset disturbs the generator, so
   the init hook runs again after the reset.

3. **`SDMMC_CMD_INIT` wedges the CIU**, so that bit is cleared.

4. **The card clock must keep running.** The CIU counts its response
   timeout in card clock cycles, so `SDMMC_CLKEN_LOW_PWR` is never set.

There was also a fix to `dw_mci_prep_stop_abort()`: `SDMMC_CMD_STOP` is
only correct for `MMC_STOP_TRANSMISSION`. The upstream set also includes
`MMC_GO_IDLE_STATE` and the SDIO abort, and with those the controller
stops the command it is starting, so the card never answers. **7.2.4 has
already fixed that upstream**, so the patch does not carry the hunk
over: the four quirks above are all that is left.

The result on the board:

```
mmc0: new high speed SDHC card at address 0007
mmcblk0: mmc0:0007 SD16G 14.5 GiB
 mmcblk0: p1
```

`/dev/mmcblk0p1` then mounts on `/home`:

```
/dev/mmcblk0p1 /home vfat rw,relatime,fmask=0022,dmask=0022,codepage=437,iocharset=iso8859-1,shortname=mixed,utf8,errors=remount-ro 0 0
```

## Using the card as /home

The 8 MB boards have no `home` partition in flash, so the SD card is
`/home`. That is set in two places, and both have to agree:

- `new-files/board/espressif/esp32s3/rootfs_overlay/etc/fstab` carries the
  `mtd:home` line that the 16 MB boards use.
- `image-profiles.py` rewrites that line to
  `/dev/mmcblk0p1 /home vfat nofail 0 0` when `SD_ROOTFS_PAYLOAD=1`,
  which the 8m profile sets.

`nofail` matters: the card may be absent, and the board must still boot
and come up on the network. A missing card costs the optional userspace
(payload on `/home/opt`) and `/home/root`, and the login warning

```
Failed chdir '/home/root'
```

which is cosmetic.

Two scripts care about the card being present:

- `S04sd-payload` deploys the optional userspace from the flash payload to
  `/home/opt` on the card. It waits for `/dev/mmcblk0p1` to appear (the
  card is probed asynchronously and can lose the race against the
  inittab's `mount -a`) and mounts `/home` itself if the fstab mount has
  not happened yet.
- `S03keepconfig` keeps `/etc/wpa_supplicant.conf`, `shadow` and the
  dropbear host keys across a reflash by copying them to
  `/home/.etc-backup` and restoring them. **This is why the SD card
  matters even when only the network is at stake**: a board whose card is
  missing loses its WiFi credentials and its SSH host key on every
  update. Delete `/home/.etc-backup/disabled` (or touch
  `/home/.etc-backup/disabled`) to turn the behaviour off.

## Checking the card

Over a shell on the board:

```sh
grep mmcblk0 /proc/mounts      # is it mounted, and is it rw?
df -h /home                    # size and free space
ls /home                       # what is on it
```

A write test that proves the card is really writable, not just mounted:

```sh
dd if=/dev/urandom of=/home/.write-probe bs=4096 count=64 2>/dev/null
sha256sum /home/.write-probe | cut -c1-32
dd if=/home/.write-probe bs=4096 count=64 2>/dev/null | sha256sum | cut -c1-32
rm -f /home/.write-probe
```

The two hashes must match.

Note that the card is **FAT32**, which has no journal. A card that was
removed while mounted, or that lost power mid-write, comes back with:

```
FAT-fs (mmcblk0p1): Volume was not properly unmounted. Some data may be corrupt. Please run fsck.
```

That warning is expected after an unclean shutdown and is not a driver
fault. Run `fsck` on a card removed from the board.

## This branch: the same work on Linux 7.2.4

The driver above was first written against **6.11** from
`jcmvbkbc/linux-xtensa` (tag `xtensa-6.11-esp32-tag`), the tree the
ePaper branch builds against. `origin/main` builds **Linux 7.2.4** from
kernel.org instead, with a different patch series.

The four driver quirks are properties of the *fused controller*, not of
the kernel version, so they carry over unchanged. The code around them
does not: `dw_mmc` was restructured between 6.11 and 7.2.4, the old
patch does not apply (one hunk fails and another lands in the wrong
function), and the `prep_stop_abort` fix is no longer needed because
upstream has it.

`11-kernel-esp32s3-sdmmc-driver.patch` on this branch is therefore
written again rather than ported, and `build/check-patches.py` applies
the whole chain to a pristine 7.2.4 tree and says what it found.

### What 7.2.4 already has

Worth writing down, because it changes the size of the job: the ESP32
support is **upstreamed** in 7.2.4. Applying the 62-patch series to a
pristine 7.2.4 tree, 19 of the patches add nothing -- the ESP32 serial
drivers, the GPIO driver, the SPI host driver, the clock providers, the
interrupt matrix, the MTD support and the IPC are all in the tree
already, and `patch` reports them as "previously applied".

The series still builds the board -- it is mostly a series of no-ops
now -- but the 7.2.4 base is the real source of the ESP32 support.

### Two symbols the kernel config no longer has

The 6.11 configs carried two symbols that 7.2.4 does not, and a config
that still names them fails in a way that looks like something else:

- **`CONFIG_MMC_BLOCK` is gone.** The MMC block layer is part of the MMC
  subsystem now, so `olddefconfig` drops the symbol, the config check
  reports a statement the tree cannot carry, and the SD card's block
  device is never asked for.
- **`CONFIG_BUILTIN_DTB_SOURCE` is now `CONFIG_BUILTIN_DTB_NAME`.**

The 8 MB configs are generated from the 7.2.4 16 MB one, so they follow
mainline's spelling throughout.

### The XIAO's SD slot is a different slot

The XIAO ESP32S3 Sense has its SD slot on the **Sense expansion
board**, wired to GPIO21 (CS), GPIO7 (SCK), GPIO8 (MISO) and GPIO9
(MOSI) -- an SPI card, not an SDMMC one. That is what
`09-kernel-xiao-sense-pins.patch` is for, and it is a separate board
from the ePaper-154 this document is about.

On the 8 MB image the card is enabled with `CONFIG_MMC_SPI=y` and
`spi-max-frequency = <20000000>`; see
[xiao-s3-sense-8m.md](xiao-s3-sense-8m.md) for the working pin routing,
the `/home` mount and the WiFi credential flow.

## What the 7.2.4 board needed on top of the 6.11 work

The 6.11 board found the card. The 7.2.4 one did not, and the reason
was not in the driver: it was in the device tree, in the boot arguments,
and in the order the consoles were named in. All three are worth
writing down, because each of them looks like something else.

### The SDMMC module was held in reset

The probe ran and said:

```
dw_mmc 60028000.sdio: Version ID is 0000
dw_mmc 60028000.sdio: DW MMC controller at irq 5,16 bit host data width,1 deep fifo
mmc_host mmc0: card is non-removable.
mmc_host mmc0: Bus speed = 40000000Hz (req 400000Hz, actual 400000HZ div = 50)
```

and then nothing: the card never answered. "Version ID is 0000" is the
give-away. A module whose registers read as zero and ignore writes is a
module **held in reset**, and the SDMMC has two gates that the firmware
never opens, because the firmware does not use the SDMMC:

| what | where | bit |
|---|---|---|
| the module's reset | `PERIP_RST_EN1` (0x600c0024) | 7 |
| the module's register clock | `PERIP_CLK_EN1` (0x600c001c) | 7 |

Both are in the SYSTEM block. `11-kernel-esp32s3-sdmmc-driver.patch`
now releases the reset and opens the clock gate in the driver's init
hook, before the clock generator is programmed. With that:

```
mmc0: new high speed SDHC card at address 0007
mmcblk0: mmc0:0007 SD16G 14.5 GiB
 mmcblk0: p1
```

### The device tree's reset line was a trap

The board tree gave the SDMMC node a reset:

```dts
resets = <&reset 39>;
reset-names = "reset";
```

Two things are wrong with it. The card has no reset wire -- it is a
plain microSD slot, CLK 39, CMD 41, D0 40 -- so there is nothing to
reset. And the "reset controller" the property points at is the RTC and
clock register block, not a set of peripheral resets: asserting line 39
writes a bit into the clock configuration.

The line was not harmless. It was the reason the card was ever found:
the generic reset driver asserted it around the probe, and the bit it
wrote happened to be the SDMMC's reset line, which the driver then
deasserted -- so the module came out of reset by accident, at the wrong
address, and the kernel's clock configuration was rewritten on the way.

**The general lesson: on this SoC the "reset controller" in the device
tree is not a reset controller.** The peripheral resets live in
`PERIP_RST_EN0`/`PERIP_RST_EN1`, and the reset lines are numbered per
register.

### The console order decided where the userspace's output went

With the card found, the board still looked dead: the kernel's messages
appeared, and nothing the init scripts printed did. The board tree
named its consoles like this:

```
console=ttyGS3 console=ttyS0,115200n8
```

The **last** console on the command line is `/dev/console`, and the
userspace writes there. So `/dev/console` was the UART0 -- which is not
wired to anything on this board -- and every message from the init
scripts went nowhere. The kernel writes to every registered console,
which is why the kernel's own messages were not affected and why the
boot looked like it stopped.

The order has to be:

```
console=ttyS0,115200n8 console=ttyGS3
```

The board's serial console is the USB one (`ttyGS3`), and the getty
runs on it.

### The board's own boot arguments

The SoC tree says `quiet`, which hides the kernel's boot messages: the
memory report, the card's detection and every failure go unread. A
board that is not working then looks like a board that is hanging.

The board tree now carries the arguments it was developed against:

```
earlycon=esp32s3uart,mmio32,0x60000000,115200n8,40000000
console=ttyS0,115200n8 console=ttyGS3
debug rw root=mtd:rootfs rootfstype=cramfs
no_hash_pointers panic=10 panic_console_replay
```

`debug` also turns off the pointer hashing, which the 6.11 tree had
(`no_hash_pointers`): the kernel then prints the addresses it is
actually using, which is what a board that does not boot needs.

## Verified on the board

The 8 MB board, Linux 7.2.4, the fork kernel with the bank allocator:

```
[    1.419365] dw_mmc 60028000.sdio: Version ID is 270a
[    1.701933] mmc0: new high speed SDHC card at address 0007
[    1.745996] mmcblk0: mmc0:0007 SD16G 14.5 GiB
[    1.804743]  mmcblk0: p1
[    2.342627] FAT-fs (mmcblk0p1): Volume was not properly unmounted. Some data may be corrupt. Please run fsck.
```

and the card mounted read-write on `/home`:

```
/dev/mmcblk0p1 on /home type vfat (rw,relatime,fmask=0022,dmask=0022,codepage=437,iocharset=iso8859-1,shortname=mixed,utf8,errors=remount-ro)
```

A write test, the one in "Checking the card" above, passes: the file
written on the board reads back with the same SHA256, and the bytes
fetched over the network hash the same on the host.

The card was left dirty by an earlier unclean shutdown, which is what the
`FAT-fs` warning above is. It is not a driver fault: a clean unmount
clears the flag, and the card is read-write again afterwards.

## Files

| file | what it does |
|---|---|
| `new-files/board/espressif/esp32s3/patches/linux/10-kernel-epaper-154-pins.patch` | the board device tree: the SDMMC node, the GPIO matrix routing, and the function-1 pin mux |
| `new-files/board/espressif/esp32s3/patches/linux/11-kernel-esp32s3-sdmmc-driver.patch` | the `dw_mmc` glue: PIO, the clock generator, and the CIU workarounds |
| `new-files/board/espressif/esp32s3/rootfs_overlay/etc/fstab` | the `mtd:home` line that `image-profiles.py` rewrites for the SD card |
| `new-files/board/espressif/esp32s3/rootfs_overlay/usr/sbin/sd-payload` | deploys the optional userspace to the card |
| `new-files/board/espressif/esp32s3/rootfs_overlay/etc/init.d/S03keepconfig` | keeps the WiFi credentials and host keys on the card across updates |
| `new-files/board/espressif/esp32s3/rootfs_overlay/usr/sbin/home-init` | seeds `/home` when the card is there |
