#!/usr/bin/env bash
#
# picoflash.sh - programs an RP2040 or RP2350 image into a board through a
# Raspberry Pi Debug Probe with OpenOCD. Run with -h for the full description.
#
set -euo pipefail

PROG=$(basename "$0")
PROBE_ID=2e8a:000c	# Raspberry Pi Debug Probe / debugprobe firmware (CMSIS-DAP v2)
CHIP=
SPEED=5000
ADDR=0x10000000
AUTO_ATTACH=1
VERBOSE=

usage() {
	cat <<EOF
Usage: $PROG [options] <image>

Programs an RP2040 or RP2350 firmware image into the flash of a board through a
Raspberry Pi Debug Probe (or a Pico running the debugprobe firmware) using
OpenOCD, verifies it, and resets the board so that it runs the new image. The
probe is expected to be attached to WSL with usbipd-win.

Arguments:
  <image>       The image to program. Supported formats:
                  .elf  Load addresses are taken from the file. Preferred.
                  .bin  Raw image, written at the load address (see -a).
                  .hex  Intel HEX; load addresses are taken from the file.
                OpenOCD cannot program UF2 files. Use the .elf or .bin from the
                same build, or copy the .uf2 to the board in BOOTSEL mode.

Options:
  -c <chip>     Target chip: rp2040, rp2350 or rp2350-riscv. When omitted, the
                chip is detected by connecting to the board (see below).
  -s <khz>      SWD clock in kHz (default: $SPEED). Lower it, for example to
                1000, when long or unshielded wires cause transfer errors.
                Raising it has little effect over usbipd (see Performance).
  -a <addr>     Load address for .bin images (default: $ADDR, the start
                of flash). Ignored for .elf and .hex images.
  -n            Do not attach the probe to WSL automatically.
  -v            Print the complete OpenOCD output.
  -h, --help    Print this help and exit.

Chip detection:
  Without -c, the script connects to the board with the OpenOCD target
  configurations rp2350, rp2350-riscv and rp2040, in that order, and uses the
  first one through which core 0 can be examined. Each attempt takes less than
  a second and does not halt or reset the board.

  An RP2350 runs either its Arm or its RISC-V cores, and the debugger can only
  reach the cores that are currently running. The configuration therefore
  follows what the board is running now, not the architecture of the new
  image. When the new image is built for the other architecture, the bootrom
  switches architecture when it boots it.

WSL and the probe:
  The probe is a USB device of the Windows host and must be attached to WSL
  with usbipd-win. When the probe ($PROBE_ID) is not visible in WSL and
  usbipd.exe can be run from WSL, the script looks up its bus id and runs:
      usbipd.exe attach --wsl --busid <busid>
  This only works for a device that has been shared once, from an elevated
  Windows prompt:
      usbipd bind --busid <busid>
  Run "usbipd list" on Windows to find the bus id. Use -n to skip the
  automatic attach.

  The current user needs access to the probe's USB device. If OpenOCD reports
  a permission error, install the udev rule shipped with OpenOCD
  (60-openocd.rules) or add the user to the plugdev group.

Programming sequence:
  1. reset halt            Reset the chip and halt the cores.
  2. clk_sys <= 150 MHz    A debug reset (SYSRESETREQ) does not reset the clock
                           generators, so an overclocked image leaves clk_sys at
                           its own speed, too fast for the bootrom flash
                           routines that OpenOCD calls. When clk_sys runs from
                           PLL_SYS above 150 MHz, its divider is raised to bring
                           it to 150 MHz or below. A 12 MHz crystal is assumed.
  3. write and verify      Erase and write the flash, then compare a checksum
                           computed on the chip with the image.
  4. reset run             Reset the chip and start the new image.

  Target RAM is used as a buffer without the backup and restore that the stock
  OpenOCD configurations perform, as the chip is reset afterwards anyway.

Performance:
  Over usbipd the transfer rate is bounded by USB round-trip latency, not by
  the SWD clock: image data reaches the chip at roughly 85 KB/s. Including
  erase, programming and verification, a 2 MB image takes about 45 seconds.

Exit status:
  0  The image was programmed and verified.
  1  Programming failed, or the probe or board could not be found.
  2  Invalid command line.

Examples:
  $PROG build/blink.elf
  $PROG -c rp2040 build/blink.bin
  $PROG -s 1000 -v firmware.hex

Requirements:
  - OpenOCD with RP2040 and RP2350 support: the Raspberry Pi fork, or upstream
    OpenOCD recent enough to provide target/rp2350.cfg.
  - usbipd-win on the Windows host.
  - lsusb (usbutils) for the probe check. Without it the check is skipped.
EOF
}

die() {
	echo "$PROG: $*" >&2
	exit 1
}

usage_error() {
	echo "$PROG: $*" >&2
	echo "Try '$PROG -h' for more information." >&2
	exit 2
}

# Tcl for step 2 of the programming sequence (see usage). Raising the divider of
# a running clock is glitch-free.
CAP_CLK_SYS='
proc rd32 {addr} {
	return [read_memory $addr 32 1]
}
proc cap_clk_sys {clocks pll div_lsb} {
	set ctrl [rd32 [expr {$clocks + 0x3c}]]
	if {($ctrl & 0xe1) != 1} return
	set refdiv [expr {[rd32 $pll] & 0x3f}]
	set fbdiv [expr {[rd32 [expr {$pll + 0x8}]] & 0xfff}]
	set prim [rd32 [expr {$pll + 0xc}]]
	set postdiv [expr {(($prim >> 16) & 7) * (($prim >> 12) & 7)}]
	set div [expr {[rd32 [expr {$clocks + 0x40}]] >> $div_lsb}]
	if {!$refdiv || !$postdiv || !$div} return
	set pll_khz [expr {12000 * $fbdiv / $refdiv / $postdiv}]
	if {$pll_khz / $div <= 150000} return
	set new [expr {($pll_khz + 149999) / 150000}]
	mww [expr {$clocks + 0x40}] [expr {$new << $div_lsb}]
	echo "clk_sys lowered from [expr {$pll_khz / $div / 1000}] to [expr {$pll_khz / $new / 1000}] MHz for programming"
}'

# ocd <chip> <commands>: runs OpenOCD against the probe; all output goes to stdout.
ocd() {
	openocd -f interface/cmsis-dap.cfg -f "target/$1.cfg" -c "adapter speed $SPEED" -c "$2" 2>&1
}

probe_present() {
	lsusb -d "$PROBE_ID" > /dev/null 2>&1
}

attach_probe() {
	local busid
	busid=$(usbipd.exe list 2> /dev/null | tr -d '\r' | awk -v id="$PROBE_ID" '$2 == id { print $1; exit }')
	[ -n "$busid" ] || die "no Debug Probe ($PROBE_ID) is connected to the Windows host"
	echo "Attaching the probe (bus id $busid) to WSL"
	usbipd.exe attach --wsl --busid "$busid" > /dev/null ||
		die "usbipd attach failed; share the probe once from an elevated Windows prompt with: usbipd bind --busid $busid"
	for _ in $(seq 20); do
		probe_present && return
		sleep 0.5
	done
	die "the probe was attached but did not appear in WSL"
}

detect_chip() {
	local chip
	for chip in rp2350 rp2350-riscv rp2040; do
		if grep -q "core0\] Examination succeed" <<< "$(ocd "$chip" "init; exit")"; then
			echo "$chip"
			return
		fi
	done
	return 1
}

[ "${1:-}" = "--help" ] && { usage; exit 0; }
while getopts ":c:s:a:nvh" opt; do
	case $opt in
		c) CHIP=$OPTARG ;;
		s) SPEED=$OPTARG ;;
		a) ADDR=$OPTARG ;;
		n) AUTO_ATTACH= ;;
		v) VERBOSE=1 ;;
		h) usage; exit 0 ;;
		:) usage_error "option -$OPTARG requires an argument" ;;
		*) usage_error "unknown option -$OPTARG" ;;
	esac
done
shift $((OPTIND - 1))
[ $# -eq 1 ] || usage_error "expected exactly one image file"
IMAGE=$1

case $CHIP in
	"" | rp2040 | rp2350 | rp2350-riscv) ;;
	*) usage_error "unknown chip '$CHIP' (expected rp2040, rp2350 or rp2350-riscv)" ;;
esac
[[ $SPEED =~ ^[0-9]+$ ]] || usage_error "SWD clock must be a number in kHz: $SPEED"
[ -f "$IMAGE" ] || die "$IMAGE: no such file"
command -v openocd > /dev/null || die "openocd not found in PATH"

case ${IMAGE,,} in
	*.elf | *.hex) LOAD_ADDR= ;;
	*.bin) LOAD_ADDR=$ADDR ;;
	*.uf2) die "OpenOCD cannot program UF2 files; use the .elf or .bin from the same build" ;;
	*) die "$IMAGE: unsupported file type (expected .elf, .bin or .hex)" ;;
esac

if command -v lsusb > /dev/null && ! probe_present; then
	if [ -n "$AUTO_ATTACH" ] && command -v usbipd.exe > /dev/null; then
		attach_probe
	else
		die "no Debug Probe ($PROBE_ID) found in WSL; attach it from Windows with: usbipd attach --wsl --busid <busid>"
	fi
fi

if [ -z "$CHIP" ]; then
	CHIP=$(detect_chip) || die "no RP2040 or RP2350 answered; check the SWD wiring and that the board is powered"
	echo "Detected $CHIP"
fi

# CLOCKS and PLL_SYS base addresses, and the bit position of CLK_SYS_DIV.INT
case $CHIP in
	rp2040) CLOCKS=0x40008000 PLL_SYS=0x40028000 DIV_LSB=8 ;;
	*) CLOCKS=0x40010000 PLL_SYS=0x40050000 DIV_LSB=16 ;;
esac

# target/rp2350.cfg selects the SYSRESETREQ reset method for core 0 only. Core 1
# keeps VECTRESET, which the Cortex-M33 lacks, so OpenOCD warns on every reset
# before falling back to SYSRESETREQ. Set it explicitly to silence the warning.
RESET_CFG=
if [ "$CHIP" = rp2350 ]; then
	RESET_CFG='$_TARGETNAME_1 cortex_m reset_config sysresetreq'
fi

echo "Programming $IMAGE"
rc=0
out=$(ocd "$CHIP" "$CAP_CLK_SYS
	\$_FLASH_TARGET configure -work-area-backup 0
	$RESET_CFG
	init
	reset halt
	cap_clk_sys $CLOCKS $PLL_SYS $DIV_LSB
	echo [flash write_image erase {$IMAGE} $LOAD_ADDR]
	echo [verify_image {$IMAGE} $LOAD_ADDR]
	reset run
	shutdown" | tee ${VERBOSE:+/dev/stderr}) || rc=$?
if [ $rc -ne 0 ] || ! grep -q "^verified [0-9]* bytes" <<< "$out"; then
	if [ -z "$VERBOSE" ]; then
		grep -E "^(Error|Warn)" <<< "$out" | grep -vE "busy command|late transfer" | tail -5 >&2 || true
		echo "Run with -v for the complete OpenOCD output." >&2
	fi
	die "programming failed"
fi
[ -n "$VERBOSE" ] || grep -E "^(clk_sys lowered|wrote|verified) " <<< "$out" || true
echo "Programmed, verified and started in $SECONDS s"
