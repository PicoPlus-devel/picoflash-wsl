# picoflash-wsl

`picoflash.sh` programs a firmware image into an RP2040 or RP2350 board through a
Raspberry Pi Debug Probe, from Windows Subsystem for Linux (WSL). It runs OpenOCD,
verifies the result and starts the new image. One command does all of it:

```sh
picoflash.sh build/app.elf
```

The script accepts `.elf`, `.bin` and Intel `.hex` images. It works on the RP2040
and on the RP2350, whether the RP2350 runs its Arm or its RISC-V cores.

## Contents

- [Purpose](#purpose)
- [How it works](#how-it-works)
- [Requirements](#requirements)
- [Setup](#setup)
- [Usage](#usage)
- [Examples](#examples)
- [Notes](#notes)
- [Troubleshooting](#troubleshooting)

## Purpose

Programming a board over SWD is more reliable than copying a UF2 file in BOOTSEL
mode. The board does not have to be unplugged, no button has to be held, and the
result is verified. From WSL, however, it takes several steps that are tedious to
repeat and easy to get wrong. `picoflash.sh` takes care of them:

- **The probe belongs to Windows.** WSL 2 sees a USB device only after it has been
  attached with [usbipd-win](https://github.com/dorssel/usbipd-win). That
  attachment is lost when the probe is unplugged or WSL is restarted. OpenOCD then
  only reports that it cannot find a CMSIS-DAP device. The script notices that the
  probe is missing, looks up its bus id and attaches it to WSL.
- **OpenOCD needs the right configuration.** Each chip has its own target
  configuration. An RP2350 is reached through a different one depending on
  whether it currently runs its Arm or its RISC-V cores. The script detects the
  chip by connecting to the board, so the configuration does not have to be named.
- **Overclocked firmware breaks flash programming.** Many RP2040 and RP2350
  applications, such as emulators and programs that generate video, run the system
  clock well above its nominal speed. A reset through the debugger does not reset
  the clock generators. The chip therefore still runs at that speed when OpenOCD
  calls the flash routines in the bootrom, which is too fast for them, and
  programming fails. The script lowers the system clock to 150 MHz or below before
  it writes.
- **The result should be clear.** The script verifies the written image with a
  checksum computed on the chip, resets the board into the new image and prints a
  short summary. Its exit status tells whether programming succeeded, so it can be
  used in other scripts.

## How it works

Before it connects to the board, the script:

1. Checks the command line and the image. A `.uf2` file is refused, with a hint
   to use the `.elf` or `.bin` from the same build instead.
2. Checks with `lsusb` that the probe (USB id `2e8a:000c`) is visible in WSL. If
   it is not, the script finds the probe's bus id with `usbipd.exe list`, runs
   `usbipd.exe attach --wsl --busid <busid>` and waits up to 10 seconds for the
   probe to appear.
3. Detects the chip, unless one was named with `-c`. It tries the OpenOCD target
   configurations `rp2350`, `rp2350-riscv` and `rp2040`, in that order, and uses
   the first one through which core 0 can be examined. Each attempt takes less
   than a second and neither halts nor resets the board.

It then programs the board in a single OpenOCD session:

| Step | Action | Purpose |
|------|--------|---------|
| 1 | `reset halt` | Reset the chip and halt the cores. |
| 2 | Lower `clk_sys` | If the system clock runs from PLL_SYS above 150 MHz, raise its divider to bring it to 150 MHz or below. |
| 3 | `flash write_image erase`, `verify_image` | Erase and write the flash, then compare a checksum computed on the chip with the image. |
| 4 | `reset run` | Reset the chip and start the new image. |

The stock OpenOCD configurations save and restore the target RAM they use as a
buffer. The script skips that, which saves time, because the chip is reset
afterwards anyway.

## Requirements

### Hardware

- A **Raspberry Pi Debug Probe**, or a **Raspberry Pi Pico or Pico 2** running
  the [debugprobe](https://github.com/raspberrypi/debugprobe/releases) firmware
  (`debugprobe_on_pico.uf2` or `debugprobe_on_pico2.uf2`). Both identify
  themselves with USB id `2e8a:000c`.
- A **target board** with an RP2040 or RP2350 whose SWD pins (SWCLK, SWDIO and
  GND) can be reached:
  - With the Debug Probe, connect its `D` port to the target's debug connector or
    pins.
  - With a Pico running debugprobe, connect GP2 to SWCLK, GP3 to SWDIO and GND
    to GND.
- The target needs its own power supply. The probe does not power it.
- Optional: a connection from the probe's UART (`U` port, or GP4/GP5 on a Pico
  running debugprobe) to the target's serial console, to read its output (see
  [Watch the serial output from the start](#watch-the-serial-output-from-the-start)).

### Software

| Component | Runs on | Notes |
|-----------|---------|-------|
| Windows 10 or 11 with WSL 2 | Windows | Any common distribution. The commands below are for Ubuntu and Debian. |
| [usbipd-win](https://github.com/dorssel/usbipd-win) 4.0 or later | Windows | Shares the probe with WSL. `usbipd.exe` must be callable from WSL. |
| OpenOCD with RP2350 support | WSL | The [Raspberry Pi fork](https://github.com/raspberrypi/openocd), or upstream OpenOCD recent enough to provide `target/rp2350.cfg`. |
| Bash 4 or later, awk, grep, coreutils | WSL | Installed by default on common distributions. |
| usbutils (`lsusb`) | WSL | Optional. Without it, the probe check and the automatic attach are skipped. |
| picotool 2.0 or later | WSL | Optional. Used only in the [backup example](#back-up-a-board-before-overwriting-it). |

## Setup

### Step 1: Install usbipd-win and share the probe

On Windows, install usbipd-win from its
[releases page](https://github.com/dorssel/usbipd-win/releases) or with winget:

```powershell
winget install --interactive --exact dorssel.usbipd-win
```

Connect the probe. Then open a PowerShell or Command Prompt **as administrator**
and list the USB devices:

```powershell
usbipd list
```

```text
BUSID  VID:PID    DEVICE                                                STATE
2-4    2e8a:000c  CMSIS-DAP v2 Interface, USB Serial Device (COM25)     Not shared
```

Share the probe using its bus id. This only has to be done once. The setting
persists across reboots, but the probe may have to be shared again after it is
plugged into a different USB port.

```powershell
usbipd bind --busid 2-4
```

Attaching the shared probe to WSL does not need administrator rights. The script
does it itself. Check that WSL can run `usbipd.exe`:

```sh
command -v usbipd.exe
# /mnt/c/Program Files/usbipd-win/usbipd.exe
```

If nothing is printed, Windows `PATH` entries are not passed to WSL
(`appendWindowsPath = false` under `[interop]` in `/etc/wsl.conf`). Either add the
usbipd-win directory to `PATH`, or attach the probe by hand and use the `-n`
option.

### Step 2: Install OpenOCD

**Option A: build the Raspberry Pi fork (recommended).**

```sh
sudo apt install git build-essential automake autoconf libtool texinfo pkg-config libusb-1.0-0-dev
git clone https://github.com/raspberrypi/openocd.git --branch sdk-2.0.0 --recursive --depth=1
cd openocd
./bootstrap
./configure --disable-werror
make -j"$(nproc)"
sudo make install
```

This installs `openocd` in `/usr/local/bin` and its configuration scripts in
`/usr/local/share/openocd/scripts`. Check the installation:

```sh
openocd --version
ls /usr/local/share/openocd/scripts/target/rp2350.cfg
```

**Option B: use the OpenOCD installed by the Raspberry Pi Pico extension for
VS Code.** The extension places a prebuilt OpenOCD in
`~/.pico-sdk/openocd/<version>/`. It needs two libraries that are not always
installed, and its directory has to be on `PATH`:

```sh
sudo apt install libftdi1-2 libhidapi-hidraw0
export PATH="$HOME/.pico-sdk/openocd/0.12.0+dev:$PATH"
export OPENOCD_SCRIPTS="$HOME/.pico-sdk/openocd/0.12.0+dev/scripts"
```

Replace `0.12.0+dev` with the version directory on your system, and add the two
`export` lines to `~/.bashrc` to keep them.

### Step 3: Install usbutils

```sh
sudo apt install usbutils
```

### Step 4: Give your user access to the probe

Without access rights, OpenOCD can only use the probe as root. OpenOCD ships a
udev rules file that grants the `plugdev` group access to every CMSIS-DAP
adapter, the Debug Probe included. Install it and add your user to that group:

```sh
sudo cp /usr/local/share/openocd/contrib/60-openocd.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules
sudo udevadm trigger
sudo usermod -aG plugdev "$USER"
```

The file is also in the `contrib/` directory of the OpenOCD source tree. The new
group membership takes effect in a new login. Close all WSL windows, or run
`wsl --terminate <distribution>` from Windows.

udev rules only work in WSL when systemd is enabled. That is the default for
current Ubuntu images. Otherwise, add the following to `/etc/wsl.conf` and run
`wsl --shutdown` from Windows:

```ini
[boot]
systemd=true
```

### Step 5: Install the script

```sh
git clone https://github.com/PicoPlus-devel/picoflash-wsl.git
mkdir -p ~/.local/bin
install -m 755 picoflash-wsl/picoflash.sh ~/.local/bin/
```

On Ubuntu, `~/.local/bin` is added to `PATH` at login once the directory exists.
On other distributions, add it to `PATH`, or install the script in
`/usr/local/bin` instead.

### Step 6: Check the setup

```sh
picoflash.sh -h
```

Then connect a target and program a known image, such as `blink.elf` from
[pico-examples](https://github.com/raspberrypi/pico-examples):

```sh
picoflash.sh pico-examples/build/blink/blink.elf
```

## Usage

```text
picoflash.sh [options] <image>
```

### Image formats

| Extension | Handling |
|-----------|----------|
| `.elf` | Load addresses are taken from the file. Preferred. |
| `.bin` | Raw image, written at the load address given with `-a` (default: start of flash). |
| `.hex` | Intel HEX. Load addresses are taken from the file. |
| `.uf2` | Not supported. OpenOCD cannot program UF2 files. Use the `.elf` or `.bin` from the same build, or copy the `.uf2` to the board in BOOTSEL mode. |

A Pico SDK project that calls `pico_add_extra_outputs()` produces the `.elf`,
`.bin`, `.hex` and `.uf2` side by side.

### Options

| Option | Description | Default |
|--------|-------------|---------|
| `-c <chip>` | Target chip: `rp2040`, `rp2350` or `rp2350-riscv`. Skips chip detection. | Detected |
| `-s <khz>` | SWD clock in kHz. Lower it, for example to 1000, when long or unshielded wires cause transfer errors. | 5000 |
| `-a <addr>` | Load address for `.bin` images. Ignored for `.elf` and `.hex`. | `0x10000000` (start of flash) |
| `-n` | Do not attach the probe to WSL automatically. | Attach |
| `-v` | Print the complete OpenOCD output. | Off |
| `-h`, `--help` | Print the built-in help and exit. | |

### Exit status

| Status | Meaning |
|--------|---------|
| 0 | The image was programmed and verified. |
| 1 | Programming failed, or the probe, the board, the image or OpenOCD could not be found. |
| 2 | Invalid command line. |

## Examples

### Program an ELF file

This is the usual case. The ELF file contains its own load addresses, so no
options are needed:

```sh
picoflash.sh build/app.elf
```

A run in which the probe still had to be attached and the board was running an
overclocked image (the sizes and times are only an illustration):

```text
Attaching the probe (bus id 2-4) to WSL
Detected rp2350
Programming build/app.elf
clk_sys lowered from 252 to 126 MHz for programming
wrote 413696 bytes from file build/app.elf in 5.012481s (80.598 KiB/s)
verified 413696 bytes in 0.204937s (1971.336 KiB/s)
Programmed, verified and started in 9 s
```

The first line appears only when the probe was not yet attached to WSL. The
`clk_sys` line appears only when the board was running above 150 MHz. The `wrote`
and `verified` lines come from OpenOCD.

### Program a raw binary

A `.bin` file has no addresses. By default it is written at `0x10000000`, the
start of flash, from where the chip boots:

```sh
picoflash.sh build/app.bin
```

### Program a raw binary at another address

Use `-a` to write a binary elsewhere in flash. One example is an application area
that lies behind a bootloader that stays at the start of flash. The address is the
flash address as the CPU sees it: `0x10000000` plus the offset in flash. Here the
offset is 512 KB:

```sh
picoflash.sh -a 0x10080000 app.bin
```

### Program an Intel HEX file

```sh
picoflash.sh firmware.hex
```

### Name the chip

Naming the chip skips the detection attempts. Give the configuration for what the
board runs **now**, not for the new image (see [Notes](#notes)):

```sh
picoflash.sh -c rp2040 build/app.elf         # RP2040
picoflash.sh -c rp2350 build/app.elf         # RP2350 currently running its Arm cores
picoflash.sh -c rp2350-riscv build/app.elf   # RP2350 currently running its RISC-V cores
```

### Use a lower SWD clock

Long, loose or unshielded wires between the probe and the board can cause transfer
errors. A lower SWD clock usually solves this:

```sh
picoflash.sh -s 1000 build/app.elf
```

### Find out why programming failed

When programming fails, the script prints the last few error and warning lines
from OpenOCD:

```text
Detected rp2040
Programming build/app.elf
Error: ...
Run with -v for the complete OpenOCD output.
picoflash.sh: programming failed
```

Run it again with `-v` to see the complete OpenOCD output as it happens. The
output goes to standard error, so it can be saved to a file:

```sh
picoflash.sh -v build/app.elf
picoflash.sh -v build/app.elf 2> openocd.log
```

### Do not attach the probe automatically

Attaching a device to WSL takes it away from Windows. Use `-n` when the script
must not do this on its own. Examples are a probe that is in use by a Windows tool,
or several probes connected to the PC, of which the script would attach the first
one listed. With `-n`, the script stops with an error if no probe is visible in
WSL. Attach the right probe by hand first:

```sh
usbipd.exe attach --wsl --busid 2-4
picoflash.sh -n build/app.elf
```

### Build and program in one step

```sh
cmake --build build && picoflash.sh build/app.elf
```

The exit status can be used in a script:

```sh
#!/usr/bin/env bash
if ! picoflash.sh build/app.elf; then
	echo "The board was not updated." >&2
	exit 1
fi
```

### Watch the serial output from the start

The Debug Probe also has a UART bridge. In WSL it appears as `/dev/ttyACM0` while
the probe is attached. Boot messages are printed right after the reset that starts
the new image, so they are missed if the port is opened afterwards. Open it before
programming:

```sh
stty -F /dev/ttyACM0 115200 cs8 -parenb -cstopb cread clocal raw -echo
timeout 120 cat /dev/ttyACM0 &
picoflash.sh build/app.elf
wait
```

The timeout starts when `cat` starts, not when the board boots. It must cover the
programming time (about 45 seconds for a 2 MB image) plus the time you want to
watch the output. `wait` returns when the timeout expires.

`cs8` is set explicitly because `raw` does not change the number of data bits. A
port left at a different setting gives unreadable output. If other serial devices
are attached, the port may have a different number. `ls /dev/serial/by-id/` shows
which one belongs to the probe. For an interactive terminal, run
`minicom -D /dev/ttyACM0 -b 115200` in a second window instead.

### Back up a board before overwriting it

The script writes the image wherever the image says. A standalone image therefore
overwrites whatever is at the start of flash, such as a bootloader. To keep a copy
first, read the flash with OpenOCD. This only reads, and the board keeps running:

```sh
openocd -f interface/cmsis-dap.cfg -f target/rp2350.cfg -c "adapter speed 5000" \
	-c "init; dump_image backup.bin 0x10000000 0x400000; shutdown"
```

`0x400000` is 4 MB, the flash size of a Pico 2. Use `0x200000` for a Pico, or the
flash size of your board. Use `target/rp2040.cfg` for an RP2040, or
`target/rp2350-riscv.cfg` for an RP2350 running its RISC-V cores.

To see what the backup contains, and to restore it later:

```sh
picotool info -a backup.bin -t bin
picoflash.sh backup.bin
```

## Notes

- **RP2350 architecture.** An RP2350 runs either its Arm or its RISC-V cores, and
  the debugger can only reach the cores that are running. Chip detection, and the
  `-c` option, therefore follow what the board runs now, not the architecture of
  the new image. A RISC-V image can be programmed into a board that runs Arm code,
  and the other way round. The bootrom switches architecture when it boots the
  new image.
- **Crystal frequency.** The clock check assumes a 12 MHz crystal, as on the
  Raspberry Pi boards and most others. With a different crystal the calculated
  frequency is wrong, and an overclocked board may not be slowed down enough for
  programming.
- **Speed.** Over usbipd, the transfer rate is limited by USB round-trip latency,
  not by the SWD clock. Image data reaches the chip at roughly 85 KB/s. Including
  erase, programming and verification, a 2 MB image takes about 45 seconds.
  Raising `-s` above the default makes little difference.
- **What is erased.** Only the flash sectors covered by the image are erased and
  written. The rest of the flash, such as saved settings beyond the end of the
  image, is kept.
- **Native Linux.** The script also runs unchanged on a Linux system with the
  probe connected directly. The probe is then already visible, so the attach step
  never runs.

## Troubleshooting

| Message | Cause and remedy |
|---------|------------------|
| `no Debug Probe (2e8a:000c) is connected to the Windows host` | usbipd-win does not list the probe. Check the USB cable and run `usbipd list` on Windows. A Pico in BOOTSEL mode, or one without the debugprobe firmware, has a different USB id. |
| `usbipd attach failed; share the probe once from an elevated Windows prompt with: usbipd bind --busid <busid>` | The probe has not been shared yet, or was moved to another USB port. Run the `usbipd bind` command shown, as administrator. |
| `the probe was attached but did not appear in WSL` | WSL did not see the device within 10 seconds. Run the script again, or check `lsusb` and `dmesg` in WSL. |
| `no Debug Probe (2e8a:000c) found in WSL; attach it from Windows with: usbipd attach --wsl --busid <busid>` | The probe is not attached, and the script did not attach it because `-n` was given or `usbipd.exe` is not on `PATH` (see [Step 1](#step-1-install-usbipd-win-and-share-the-probe)). |
| `no RP2040 or RP2350 answered; check the SWD wiring and that the board is powered` | The probe works, but no chip responded. Check that SWCLK, SWDIO and GND are connected and not swapped, and that the target is powered. Try a lower clock with `-s 1000`. |
| `OpenOCD cannot program UF2 files; use the .elf or .bin from the same build` | Use the `.elf`, `.bin` or `.hex` from the same build. |
| `openocd not found in PATH` | Install OpenOCD ([Step 2](#step-2-install-openocd)), or add its directory to `PATH`. |
| OpenOCD reports a permission or access error | Your user cannot open the probe's USB device. Install the udev rules and join the `plugdev` group ([Step 4](#step-4-give-your-user-access-to-the-probe)). |
| `unable to find a matching CMSIS-DAP device` when running OpenOCD by hand | The probe is not attached to WSL. Run `usbipd.exe attach --wsl --busid <busid>`, or let `picoflash.sh` attach it. |
| Programming fails now and then, or reports transfer errors | Use shorter wires or a lower SWD clock (`-s 1000`). Run with `-v` for details. |
