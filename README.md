# HHD on CachyOS for the ASUS ROG Ally

Get **Handheld Daemon (HHD)** working properly on CachyOS for the ASUS ROG Ally: TDP, fan control, RGB, and the Armoury / Command Center buttons. Includes a guided, logged install script and a read-only health check.

> **Tested on:** CachyOS (Handheld Edition), **ASUS ROG Ally Z1 Extreme**, kernel `7.0.12-1-cachyos-deckify` (anything 6.19+ should work, since that is where the `asus-armoury` TDP driver is mainline).
> Not tested on the Ally X, Legion Go, Steam Deck, or anything else. The conflict pattern and package list should carry over to other ASUS handhelds on CachyOS, but treat anything outside the Z1 Extreme as unverified.

## Why this exists

Installing HHD "by the generic Arch instructions" on a fresh CachyOS Handheld install leaves you with **no TDP section in the UI** and **dead Armoury / Command Center buttons**. None of that is HHD's fault. It comes from three CachyOS-specific things the generic instructions never mention:

1. **TDP is a separate package.** `hhd` does controllers, RGB, and the overlay. TDP and fans come from `adjustor`. No `adjustor`, no TDP section.
2. **CachyOS ships InputPlumber**, which fights HHD over the controller and the ASUS keyboard device the buttons live on. `systemctl disable` is not enough because InputPlumber is D-Bus activated and relaunches itself. You have to mask or remove it and reboot.
3. **`systemctl enable` without `--now`** arms the service for next boot but never starts it in the current session, so it looks dead.

## Quick start (script)

```bash
git clone https://github.com/rgvxsthi/hhd-cachyos-rog-ally.git
cd Installing-Handheld-Daemon-HHD-on-ASUS-ROG-Ally-on-CachyOS
chmod +x setup.sh verify.sh
./setup.sh            # interactive; add --debug to trace every step
```

After the reboot:

```bash
./verify.sh           # read-only; add --debug for full trace
```

The script is interactive and idempotent. It refuses to run as root, checks your kernel and the ASUS power interface before changing anything, asks before removing packages, and never reboots you without asking. It runs under `bash`; if you launch it with `sh` it re-execs itself under `bash` automatically.

### Flags

- `--debug` (or `-debug`, `-d`): trace every command as it runs. Use this if something fails and you want to see exactly where.
- `--yes` (or `-y`): assume yes to prompts. Still asks before rebooting.
- `--no-reboot`: never prompt to reboot.
- `--help` (or `-h`).

### Logging

Every run of both scripts writes a timestamped log to your home directory:

- `~/hhd-setup-<timestamp>.log`
- `~/hhd-verify-<timestamp>.log`

Each script also prints a `BEGIN HHD DIAGNOSTICS ... END` block at the end. Paste that block (or attach the log) when filing an issue or asking for help. Console output keeps colour; the log file has the colour codes stripped so it stays readable.

## Manual steps

If you would rather do it by hand, or want to understand what the script does:

```bash
# 1. update + reboot into a current kernel (6.19+ has asus-armoury for TDP)
sudo pacman -Syu && reboot

# 2. after reboot, confirm the TDP backend exists BEFORE installing
uname -r                                          # want 6.19+
lsmod | grep asus_wmi                             # asus_wmi listed
cat /sys/firmware/acpi/platform_profile_choices   # low-power balanced performance

# 3. remove InputPlumber properly (mask + remove, not just disable)
sudo systemctl mask --now inputplumber
sudo pacman -R inputplumber

# 4. remove the ASUS userspace stack IF present (it fights adjustor) - see Troubleshooting
pacman -Qs asusctl rog-control-center supergfxctl

# 5. install all three packages
sudo pacman -S hhd adjustor hhd-ui

# 6. enable AND start (the --now matters)
sudo systemctl enable --now hhd@$(whoami)

# 7. reboot
reboot
```

Verify:

```bash
systemctl is-active hhd@$(whoami)                 # active
sudo journalctl -u hhd@$(whoami) -b --no-pager | grep -iE 'adjustor|asus|profile'
```

A healthy log shows the adjustor ASUS backend loading and the daemon setting the power profile:

```
- adjustor: adjustor_asus, adjustor_init, adjustor_battery, adjustor_ppd
ADJA  INFO   Setting thermal profile to '0'
AGPU  INFO   Handling energy settings for power profile 'balanced'.
```

`adjustor_asus` plus `Setting thermal profile` means TDP is working.

## Configuring it (and the overlay "errors" that aren't errors)

**Desktop mode (KDE Plasma):** open the **Handheld Daemon** app from your launcher. TDP slider, fan curves, RGB, and button bindings are all there.

**Game Mode (gamescope):** double-tap the small menu button next to the screen for the overlay.

If you check the journal from the **desktop** session you will see a wall of `OVRL` D-Bus and GL errors ending in `Overlay thread died`. That is expected. The overlay is a gamescope overlay and only renders inside the gamescope session. In desktop mode it has nothing to attach to, so it dies. Use the desktop app there. The overlay works fine in Game Mode.

## Troubleshooting

### "I installed asusctl / rog-control-center too. Do I need to remove them?"

Yes, or at least make sure `asusd` is not running. asusctl/rog-control-center and HHD's `adjustor` both drive the same ASUS power interface (the platform profile and asus-armoury PPT attributes), so running both means they fight over TDP. `asusd` also auto-starts from a udev rule when the keyboard driver loads, so "installed but not enabled" can still mean it is running.

```bash
sudo systemctl disable --now asusd
sudo pacman -R rog-control-center asusctl supergfxctl   # remove only what is installed
```

The `setup.sh` script detects and offers to remove these for you.

### Double controller / dead buttons: the `hid_asus` blacklist

Some users on **other CachyOS kernels** report that HHD does not fully take over the controller, and they had to blacklist the native ASUS HID drivers. **Only do this if you actually have the symptom.**

The symptom: open **Steam > Settings > Controller**. If you see **two** controllers, the HHD-emulated one (e.g. an Xbox 360 controller) **plus** a separate "ROG Ally", the native HID driver is leaking a second pad to Steam and you get double input. If you see only one controller, you do not need this and applying it can break input.

Fix, only in the two-controller case:

```bash
echo 'blacklist hid_asus_ally' | sudo tee /etc/modprobe.d/hhd-ally.conf
echo 'blacklist hid_asus'      | sudo tee -a /etc/modprobe.d/hhd-ally.conf
sudo mkinitcpio -P
sudo reboot
```

**Known-good baseline (no blacklist needed):** on `7.0.12-1-cachyos-deckify` with `hid_asus_ally` and `asus_armoury` loaded, Steam shows a single emulated controller and HHD grabs the raw pad cleanly. Removing InputPlumber is part of why the grab is clean. Whether you hit the double-controller case appears to depend on your CachyOS kernel flavour. Run `verify.sh` after reboot; it enumerates your controller devices and tells you whether to check for this.

### Verifying TDP actually changes

HHD controls TDP two different ways, and they look different from the terminal:

- **Presets** (silent / balanced / performance / turbo) set the ASUS *thermal profile*. The firmware then applies that profile's built-in PPT limits. The `/sys/devices/platform/asus-nb-wmi/ppt_*` files do **not** change in this mode, so watching them on a preset wrongly looks like nothing is happening.
- **Custom** writes explicit watt values to `/sys/devices/platform/asus-nb-wmi/ppt_*`, so those files do change as you drag the slider.

The reliable oracle for both is `ryzenadj`, which reads the limits straight from the SMU. It needs the `ryzen_smu` kernel module (without it, it falls back to `/dev/mem` and reads nothing):

```bash
paru -S ryzen_smu-dkms        # or: sudo pacman -S ryzen_smu-dkms
sudo modprobe ryzen_smu
sudo ryzenadj -i | grep -iE 'STAPM|PPT LIMIT'
```

Switch presets and re-run. `STAPM LIMIT` and `PPT LIMIT FAST/SLOW` should change per preset (e.g. higher on turbo than on performance). `STAPM VALUE` is live draw and only climbs toward the limit under load. Note the `asus-armoury` firmware-attributes (`/sys/class/firmware-attributes/asus-armoury/attributes/ppt_*/current_value`) are a separate BIOS-level mirror and will not track adjustor's writes, so don't use them to judge whether TDP is working.

## The "use the Bazzite kernel" advice

You will see this repeated everywhere. It does not apply cleanly to CachyOS:

- The Bazzite kernel is a Fedora / rpm kernel for an immutable OSTree system. There is no clean way to install it on an Arch-based distro like CachyOS.
- For the Ally, the power drivers (`asus-wmi` / `asus-armoury`) are mainline as of 6.19, so a current CachyOS kernel already has them. The Ally and Ally X are not on HHD's list of devices that hard-require the Bazzite kernel; only the Z13 (2025) is.
- The only genuinely kernel-dependent piece is **gyro** (the `bmi260` IMU). Test it in Steam controller settings. If gyro works, you are done. If it is dead and you want it, the Arch-native fix is the **OGC / `linux-g14`** kernel from the asus-linux g14 repo, **not** Bazzite. Note that gyro is also only exposed in **DualSense** emulation mode, not Xbox.

## Worth checking after it works

- **Gyro** in Steam controller settings (only exposed in DualSense emulation mode).
- **Sleep and wake.** Suspend, wake, confirm the controller still works and the battery did not drain. The most common Ally pain point on Linux, and usually firmware if broken.
- **BIOS / MCU firmware version:** `sudo dmidecode -s bios-version` against ASUS's support page. Linux cannot update Ally firmware cleanly, so know where you stand.
- **Battery charge limit** (the `adjustor_battery` module): cap charging at 80% in the HHD app if it lives on the charger.
- **AC vs battery TDP profiles** and a **fan curve** in the HHD app.
- **Back paddle buttons (M1 / M2)** bound in HHD's Controller section. They do nothing until mapped.

## Credits

- Handheld Daemon: https://github.com/hhd-dev/hhd
- CachyOS Handheld: https://github.com/CachyOS/CachyOS-Handheld
- asus-linux (g14 kernel, asusctl): https://asus-linux.org

## License

MIT. See [LICENSE](LICENSE).
