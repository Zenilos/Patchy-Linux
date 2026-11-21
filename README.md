# patchy — Linux for Seeed XIAO ESP32-S3 Sense (8 MB)

A self-contained flash kit for the `s3-sense` image. Flashing needs no Docker,
buildroot or ESP-IDF — just Python 3 and `esptool`.

## What is in this folder

- `flash.sh` — the flash script. Supports a full-image write, `--parts`,
  `--erase`, `--creds` and `--backup`. Run `./flash.sh --help` for details.
- `images/` — the 8 MB image (`linux-esp32s3-xiao-8m-full.bin`,
  sha256 `91420c2d…c604b0f4e56554a684`), the individual partition images,
  and `SHA256SUMS`.
- `FLASH-AND-RUN.md` — the full reference from the `s3-sense` branch:
  build provenance, console, device tree, microSD, WiFi, and verification.
- `new-files/esp-hosted/network_adapter/partition_table.esp32s3.8m` and
  `tools/credential.py` — required by `flash.sh`; leave them where they are.

## Requirements

- Seeed XIAO ESP32-S3 Sense (ESP32-S3R8, 8 MB flash, 8 MB PSRAM)
- USB-C cable; a FAT32 microSD card if you want `/home` on the card
- Python 3 and esptool: `python3 -m pip install esptool`

## Find the serial port

macOS: `/dev/cu.usbmodem*` · Linux: `/dev/ttyACM*` or `/dev/ttyUSB*`.
The Linux console is the USB port (`ttyGS3`), 115200 baud. Pass the port
explicitly with `-p` — auto-detection only checks `/dev/ttyACM*`.

## WiFi credentials (optional)

Put them in a file **outside** this folder, for example `~/xiao-wifi.txt`:

```
ssid=YOUR_WIFI_SSID
psk=YOUR_WIFI_PASSWORD
```

The script writes this into the `cred` partition before flashing. Never commit
that file — it contains your passphrase in plain text.

## Flash

```sh
cd /path/to/patchy
./flash.sh -p /dev/cu.usbmodemXXXX --creds ~/xiao-wifi.txt
```

Without a credential file:

```sh
./flash.sh -p /dev/cu.usbmodemXXXX
```

Add `--erase` to wipe the whole chip first. The full image overwrites `/etc`;
`/home` is on the SD card and is not touched. To save the board's current
`/etc`, use `./flash.sh --backup DIR -p PORT`.

## Run and verify

- Open a serial terminal at 115200 (or telnet to the board's IP).
- Log in as `root` / `only-esp32`. Telnet is on by default.
- `uname -a` → `Linux buildroot 7.2.4-forkbank … xtensa GNU/Linux`
- `ls /dev/mmcblk*` and `df -h /home` → FAT32 card mounted read-write
- `ip addr` is the source of truth for WiFi (`wifi status` is cosmetic).
- Set WiFi later with `wifi connect "SSID" "PASSWORD"`.

This board has no ePaper panel and no battery — that hardware belongs to the
`retro` folder.

## Provenance

Image: `build-output/reproduce.s3-sense-sd/artifacts` (the working build
recorded in `FLASH-AND-RUN.md`). Script, docs, partition table and helper:
branch `s3-sense`, commit `65b2ac2`.
