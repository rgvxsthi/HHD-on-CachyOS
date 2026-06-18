# HHD on CachyOS for the ASUS ROG Ally

Get **Handheld Daemon (HHD)** working properly on CachyOS for the ASUS ROG Ally: TDP, fan control, RGB, and the Armoury / Command Center buttons. Includes a guided install script and a read-only health check.

> **Tested on:** CachyOS (Handheld Edition), **ASUS ROG Ally Z1 Extreme**, kernel 6.19+.
> Not tested on the Ally X, Legion Go, Steam Deck, or anything else. The conflict pattern and package list should carry over to other ASUS handhelds on CachyOS, but treat anything outside the Z1 Extreme as unverified.

## Why this exists

Installing HHD "by the generic Arch instructions" on a fresh CachyOS Handheld install leaves you with **no TDP section in the UI** and **dead Armoury / Command Center buttons**. None of that is HHD's fault. It comes from three CachyOS-specific things the generic instructions never mention:

1. **TDP is a separate package.** `hhd` does controllers, RGB, and the overlay. TDP and fans come from `adjustor`. No `adjustor`, no TDP section.
2. **CachyOS ships InputPlumber**, which fights HHD over the controller and the ASUS keyboard device the buttons live on. `systemctl disable` is not enough because InputPlumber is D-Bus activated and relaunches itself. You have to mask or remove it and reboot.
3. **`systemctl enable` without `--now`** arms the service for next boot but never starts it in the current session, so it looks dead.

## Quick start (script)

```bash
git clone https://github.com/<your-username>/hhd-cachyos-rog-ally.git
cd hhd-cachyos-rog-ally
chmod +x setup.sh verify.sh
./setup.sh
```

The script is interactive and idempotent. It refuses to run as root, checks your kernel and the ASUS power interface before changing anything, asks before removing packages, and never reboots you without asking. Pass `-y` to skip the prompts (it still asks before rebooting).

After the reboot:

```bash
./verify.sh
```

`verify.sh` changes nothing. It prints PASS / FAIL for the kernel, `asus_wmi`, the platform profile, the three packages, InputPlumber state, the `hhd` service, and the adjustor backend.

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

# 4. remove the ASUS userspace stack IF present (it fights adjustor)
pacman -Qs asusctl rog-control-center supergfxctl
#   if present:
#   sudo systemctl disable --now asusd
#   sudo pacman -R rog-control-center asusctl supergfxctl

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

## The "use the Bazzite kernel" advice

You will see this repeated everywhere. It does not apply cleanly to CachyOS:

- The Bazzite kernel is a Fedora / rpm kernel for an immutable OSTree system. There is no clean way to install it on an Arch-based distro like CachyOS.
- For the Ally, the power drivers (`asus-wmi` / `asus-armoury`) are mainline as of 6.19, so a current CachyOS kernel already has them. The Ally and Ally X are not on HHD's list of devices that hard-require the Bazzite kernel; only the Z13 (2025) is.
- The only genuinely kernel-dependent piece is **gyro** (the `bmi260` IMU). Test it in Steam controller settings. If gyro works, you are done. If it is dead and you want it, the Arch-native fix is the **OGC / `linux-g14`** kernel from the asus-linux g14 repo, **not** Bazzite.

## Worth checking after it works

- **Gyro** in Steam controller settings (the only kernel-dependent piece).
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
