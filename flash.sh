#!/bin/sh
# Copyright (c) 2026 Paulneja. GPLv3, see LICENSE. https://github.com/paulneja/Linux-on-esp32-S3
set -eu

DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
IMG="$DIR/images"
PORT=""
ERASE=0
PARTS=0
BACKUP=""
CREDS=""

usage() {
	cat <<'EOF'
Usage: ./flash.sh [-p PORT] [--images DIR] [--parts] [--erase] [--creds FILE]
       ./flash.sh --backup DIR [-p PORT]

Requires Python 3 and esptool. Images come from images/ beside this script
unless --images points somewhere else, such as a build-output artifacts
directory.
  -p, --port PORT  Serial/COM adapter (otherwise autodetected)
  --images DIR     Read the images from DIR instead of images/
  --parts          Write separate images; preserve /home unless --erase is used
  --erase          Erase the entire chip before writing; destroys all board data
  --backup DIR     Read /etc and /home off the board into DIR and exit
  --creds FILE     Put a WiFi credential into the image before writing it
  -h, --help       Show this help

The default full-image write overwrites /etc and /home even without --erase.
--parts also overwrites /etc, including accounts and network configuration.
--parts --erase writes home.jffs2 when the directory has one; without it the
partition is left erased, which the board formats on its first write.
All inputs are checked before device access.

--creds FILE fills the WiFi credential into the cred partition of the
image before it is written. The file is plain text:

    ssid=YOUR SSID
    psk=YOUR PASSWORD

The board reads it on its first boot and joins the network on its own.
The images that are shipped have that partition blank, so without
--creds the board waits for the wifi command like any other board.

--backup takes about a minute and a half and writes etc.jffs2.bak and
home.jffs2.bak. Those hold account hashes and wifi credentials: keep them
private, and never commit them.
EOF
	exit "${1:-0}"
}

while [ $# -gt 0 ]; do
	case "$1" in
	-p|--port) PORT="${2:?-p needs a port}"; shift 2 ;;
	--images)  IMG="${2:?--images needs a directory}"; shift 2 ;;
	--erase)   ERASE=1; shift ;;
	--parts)   PARTS=1; shift ;;
	--backup)  BACKUP="${2:?--backup needs a directory}"; shift 2 ;;
	--creds)   CREDS="${2:?--creds needs a file}"; shift 2 ;;
	-h|--help) usage 0 ;;
	*) echo "unknown option: $1" >&2; usage 1 >&2 ;;
	esac
done

command -v python3 >/dev/null 2>&1 || { echo "error: Python 3 is required" >&2; exit 1; }
if command -v esptool.py >/dev/null 2>&1; then
	ESPTOOL="esptool.py"
elif command -v esptool >/dev/null 2>&1; then
	ESPTOOL="esptool"
elif python3 -c 'import esptool' >/dev/null 2>&1; then
	ESPTOOL="python3 -m esptool"
else
	echo "error: esptool not found. Install it with:" >&2
	echo "    pip install esptool" >&2
	echo "or activate your ESP-IDF environment (. \$IDF_PATH/export.sh)." >&2
	exit 1
fi

# The profile decides the partition table, the flash size and the name of
# the combined image. PROFILE= in the environment wins; otherwise the
# images directory decides, because that is what is about to be written.
# The 8 MB boards have no home partition: /home is the SD card.
PROFILE=${PROFILE:-}
FULL_IMAGE=${FULL_IMAGE:-}
if [ -z "$PROFILE" ]; then
	PROFILE=esp32s3_devkit_c1_16m
	for candidate in "$IMG"/*-full.bin; do
		[ -e "$candidate" ] || continue
		name=$(basename "$candidate")
		[ "$name" = linux-esp32s3-native-full.bin ] && continue
		PROFILE=esp32s3_devkit_c1_8m
		[ -n "$FULL_IMAGE" ] || FULL_IMAGE=$name
	done
fi
case "$PROFILE" in
esp32s3_devkit_c1_8m)
	CSV_NAME=partition_table.esp32s3.8m
	FLASH_MB=8
	;;
esp32s3_devkit_c1_16m)
	CSV_NAME=partition_table.esp32s3.16m8r
	FLASH_MB=16
	;;
*)
	echo "error: unknown PROFILE: $PROFILE" >&2
	exit 1
	;;
esac
[ -n "$FULL_IMAGE" ] || FULL_IMAGE=linux-esp32s3-native-full.bin
CSV="$DIR/new-files/esp-hosted/network_adapter/$CSV_NAME"

if [ -z "$PORT" ]; then
	for p in /dev/ttyACM0 /dev/ttyACM1 /dev/ttyUSB0 /dev/ttyUSB1; do
		[ -e "$p" ] && { PORT="$p"; break; }
	done
	[ -n "$PORT" ] || { echo "error: no board found; pass -p /dev/ttyXXX" >&2; exit 1; }
	echo "Using port $PORT (override with -p)"
fi


# Reading the two writable partitions off the board. No image is involved, so
# this runs before the preflight and leaves without touching anything else.
if [ -n "$BACKUP" ]; then
	mkdir -p "$BACKUP"
	BCSV="$CSV"
	# Offsets come from the CSV, so a recut layout backs up the right regions
	# without this script being edited. The 8 MB boards have no home
	# partition, so only /etc is read there.
	RANGES=$(python3 - "$BCSV" <<'CSVEOF'
import csv, sys
from pathlib import Path
want = ('etc', 'home')
found = {}
for row in csv.reader(Path(sys.argv[1]).open()):
    if not row or not row[0].strip() or row[0].lstrip().startswith('#'):
        continue
    name = row[0].strip()
    if name in want:
        found[name] = (int(row[3].strip(), 0), int(row[4].strip(), 0))
if 'etc' not in found:
    sys.exit('error: partition table has no etc partition')
print(' '.join('%d %d' % found[name] for name in want if name in found))
CSVEOF
	)
	# shellcheck disable=SC2086
	set -- $RANGES
	echo "==> Reading /etc and /home into $BACKUP (about 90 seconds)"
	# shellcheck disable=SC2086
	$ESPTOOL --chip esp32s3 -p "$PORT" -b 460800 --before default_reset --after hard_reset \
		read_flash "$1" "$2" "$BACKUP/etc.jffs2.bak"
	if [ $# -ge 4 ]; then
		# shellcheck disable=SC2086
		$ESPTOOL --chip esp32s3 -p "$PORT" -b 460800 --before default_reset --after hard_reset \
			read_flash "$3" "$4" "$BACKUP/home.jffs2.bak"
	fi
	echo "Saved. These hold password hashes and wifi credentials: keep them private."
	exit 0
fi

OFFSETS=$(python3 - "$IMG" "$CSV" "$PARTS" "$ERASE" "$FLASH_MB" "$FULL_IMAGE" <<'PY'
import csv
from pathlib import Path
import struct
import sys

image_dir, table = map(Path, sys.argv[1:3])
parts_mode, erase = sys.argv[3:5]
flash_size = int(sys.argv[5]) * 1024 * 1024
full_image = sys.argv[6]

def check_image(name, limit, exact=False):
    path = image_dir / name
    with path.open('rb') as stream:
        stream.seek(0, 2)
        size = stream.tell()
    if size <= 0 or size > limit or (exact and size != limit):
        raise ValueError(f'{path}: invalid size {size}; expected '
                         + (str(limit) if exact else f'1..{limit}') + ' bytes')
    return path

try:
    if parts_mode == '0':
        check_image(full_image, flash_size, exact=True)
    else:
        parts = {}
        with table.open() as stream:
            for row in csv.reader(stream):
                if not row or not row[0].strip() or row[0].lstrip().startswith('#'):
                    continue
                name = row[0].strip()
                if len(row) < 5 or name in parts:
                    raise ValueError(f'{table}: malformed or duplicate partition {name}')
                offset, size = (int(field.strip(), 0) for field in row[3:5])
                if offset < 0x9000 or size <= 0 or (offset | size) % 4096:
                    raise ValueError(f'{name}: invalid partition offset or size')
                if offset + size > flash_size:
                    raise ValueError(f'{name}: partition exceeds the {flash_size} byte flash')
                parts[name] = (offset, size)
        end = 0x9000
        for name, (offset, size) in sorted(parts.items(), key=lambda item: item[1][0]):
            if offset < end:
                raise ValueError(f'{name}: overlapping partitions')
            end = offset + size
        required = ('factory', 'etc', 'linux', 'rootfs')
        for name in required:
            if name not in parts:
                raise ValueError(f'{table}: missing {name} partition')
        check_image('bootloader.bin', 0x8000)
        binary = check_image('partition-table.bin', 0x1000).read_bytes()
        installed = {}
        for pos in range(0, len(binary) - 31, 32):
            magic, _, _, offset, size, label, _ = struct.unpack_from('<HBBII16sI', binary, pos)
            if magic != 0x50AA:
                break
            name = label.split(b'\0', 1)[0].decode('ascii')
            if name in installed:
                raise ValueError(f'partition-table.bin: duplicate partition {name}')
            installed[name] = (offset, size)
        if installed != parts:
            raise ValueError('partition-table.bin does not match CSV partition names/offsets/sizes')
        # The 8 MB boards have no home partition: /home is the SD card.
        # The cred partition is not one of these images: it is either
        # filled in later or left alone.
        images = (('factory', 'network_adapter.bin'), ('etc', 'etc.jffs2'),
                  ('linux', 'xipImage'), ('rootfs', 'rootfs.cramfs'))
        for name, filename in images:
            check_image(filename, parts[name][1])
        if 'home' in parts and erase == '1' and (image_dir / 'home.jffs2').exists():
            check_image('home.jffs2', parts['home'][1], exact=True)
        # A missing partition is written as a dash, so the caller always
        # knows which offset is which.
        print(' '.join(str(parts[name][0]) if name in parts else '-'
                       for name in ('factory', 'etc', 'linux', 'rootfs', 'home', 'cred')))
except (OSError, ValueError, struct.error) as error:
    sys.exit(f'error: preflight failed: {error}; no board data was changed')
PY
)

if [ "$PARTS" = 1 ]; then
	# shellcheck disable=SC2086
	set -- $OFFSETS
	OFF_APP=$1; OFF_ETC=$2; OFF_LINUX=$3; OFF_ROOTFS=$4; OFF_HOME=$5; OFF_CRED=$6
	set -- 0x0 "$IMG/bootloader.bin" 0x8000 "$IMG/partition-table.bin" \
		"$OFF_APP" "$IMG/network_adapter.bin" "$OFF_ETC" "$IMG/etc.jffs2" \
		"$OFF_LINUX" "$IMG/xipImage" "$OFF_ROOTFS" "$IMG/rootfs.cramfs"
	if [ "$ERASE" = 1 ]; then
		if [ "$OFF_HOME" != "-" ] && [ -f "$IMG/home.jffs2" ]; then
			set -- "$@" "$OFF_HOME" "$IMG/home.jffs2"
		elif [ "$OFF_HOME" != "-" ]; then
			echo "Note: no home.jffs2 here; /home is left erased and formatted on first write."
		else
			echo "Note: this board has no home partition; /home is the SD card."
		fi
		echo "Warning: --parts --erase resets /etc and /home; all board data will be lost."
	else
		echo "Warning: --parts preserves /home but overwrites /etc (accounts and configuration)."
	fi
else
	set -- 0x0 "$IMG/$FULL_IMAGE"
	echo "Warning: the full image overwrites /etc and /home, even without --erase."
fi

# The WiFi credential, when one was given. It goes into the cred partition
# of the flash, as plain text, so the board can read it on its first
# boot. The images that are shipped have that partition blank, so without
# --creds nothing is written into it here.
if [ -n "$CREDS" ]; then
	[ -f "$CREDS" ] || { echo "error: no such credential file: $CREDS" >&2; exit 1; }
	CRED_DIR=$(mktemp -d)
	trap 'rm -rf "$CRED_DIR"' EXIT INT TERM
	if [ "$PARTS" = 1 ]; then
		if [ "$OFF_CRED" = "-" ]; then
			echo "error: this partition table has no cred partition" >&2
			exit 1
		fi
		python3 "$DIR/tools/credential.py" "$CREDS" --table "$CSV" \
			--cred-out "$CRED_DIR/cred.bin" || exit 1
		set -- "$@" "$OFF_CRED" "$CRED_DIR/cred.bin"
	else
		# The full image already covers the whole flash, so the
		# credential goes into a copy of it rather than into a
		# second write at an address the image covers as well.
		python3 "$DIR/tools/credential.py" "$CREDS" --table "$CSV" \
			--image "$IMG/$FULL_IMAGE" --image-out "$CRED_DIR/$FULL_IMAGE" || exit 1
		set -- 0x0 "$CRED_DIR/$FULL_IMAGE"
	fi
fi

# images/ now ships a SHA256SUMS; check it when the directory has one, so a
# truncated download or a half-written artifact is caught before the erase.
if [ -f "$IMG/SHA256SUMS" ] && command -v sha256sum >/dev/null 2>&1; then
	echo "==> Verifying checksums in $IMG"
	( cd "$IMG" && sha256sum -c SHA256SUMS --quiet ) || {
		echo "error: checksum mismatch in $IMG; no board data was changed" >&2
		exit 1
	}
fi

if [ "$ERASE" = 1 ]; then
	echo "==> Erasing the whole chip (this wipes /home too)"
	# shellcheck disable=SC2086
	$ESPTOOL --chip esp32s3 -p "$PORT" -b 460800 erase_flash
fi

echo "==> Flashing validated images"
# shellcheck disable=SC2086
$ESPTOOL --chip esp32s3 -p "$PORT" -b 460800 --before default_reset --after hard_reset \
	write_flash --flash_mode dio --flash_size "${FLASH_MB}MB" --flash_freq 80m "$@"

if [ -n "$CREDS" ]; then
	cat <<'EOF'

Done. The WiFi credential went into the cred partition of the flash, so
the board joins that network on its first boot and prints its address on
the panel. The network settings are in /etc/wpa_supplicant.conf from then
on, and the wifi command changes them while the board is up.
EOF
else
	cat <<'EOF'

Done. Open the serial console at 115200 baud, e.g.:

    screen /dev/ttyACM0 115200      (or: picocom -b 115200 /dev/ttyACM0)

Log in as root / only-esp32 (the password pinned in this image). Telnet is
on by default. No WiFi is configured on a fresh flash. Connect with:

    wifi connect "YOUR SSID" "YOUR PASSWORD"

Then telnet (or ssh) in from your LAN, or keep using the serial console.
EOF
fi
