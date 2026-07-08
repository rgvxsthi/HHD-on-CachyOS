# HHD on CachyOS for ASUS ROG Ally & Lenovo Legion Go

Get **Handheld Daemon (HHD)** working properly on CachyOS: TDP, fan control, RGB, and the vendor menu buttons. The scripts **auto-detect** your device (ASUS ROG Ally family or Lenovo Legion Go family) and apply the right actions. Includes a guided, logged install script, a matching uninstaller, and a read-only health check.

> **Tested on:** CachyOS (Handheld Edition), **ASUS ROG Ally Z1 Extreme**, kernel `7.0.12-1-cachyos-deckify` (anything 6.19+ should work, since that is where the `asus-armoury` TDP driver is mainline).
> **Lenovo Legion Go support is derived from HHD's own source** (device detection, the `acpi_call` TDP path, udev `xpad` binding) and is **unverified on real hardware** — treat it as best-effort until someone confirms. See [Supported devices](#supported-devices).

## Supported devices

The device is matched from DMI `product_name` in [`lib/device-profile.sh`](lib/device-profile.sh):

| Family | Models | TDP path | Vendor conflicts removed | Controller note |
|---|---|---|---|---|
| **ASUS ROG Ally** | ROG Ally / Ally X / ROG Xbox Ally | `asus_wmi` + `asus_armoury` → `platform_profile` | asusctl, rog-control-center, supergfxctl, asusd | optional `hid_asus_ally` blacklist (double-pad case) |
| **Lenovo Legion Go** | Go (83E1), Go 2 (83N0/83N1), Go S (83L3/83N6/83Q2/83Q3) | `acpi_call` module → `/proc/acpi/call` | none exist | `xpad` bound via HHD's udev rule; on Linux 7.1+ setup offers to blacklist `hid_lenovo_go` (else gamescope plug/unplug) |

Both families share: InputPlumber removal, `power-profiles-daemon`/`tuned` masking, and the `hhd`/`hhd-ui` install. Lenovo additionally installs `acpi_call-dkms` (its TDP interface). An unrecognized device still gets the shared steps with a warning.

## Why this exists

Installing HHD "by the generic Arch instructions" on a fresh CachyOS Handheld install leaves you with **no TDP section in the UI** and **dead vendor menu buttons**. None of that is HHD's fault. It comes from CachyOS-specific things the generic instructions never mention:

1. **TDP is a separate package.** `hhd` does controllers, RGB, and the overlay. TDP and fans come from `adjustor` (merged into `hhd` as of v4). On Lenovo, TDP also needs the `acpi_call` kernel module (`acpi_call-dkms`).
2. **CachyOS ships InputPlumber**, which fights HHD over the controller and the keyboard device the buttons live on. `systemctl disable` is not enough because InputPlumber is D-Bus activated and relaunches itself. You have to mask or remove it and reboot.
3. **`power-profiles-daemon` (and `tuned`) fight adjustor** over the power profile and the PowerProfiles D-Bus name — adjustor *is* a drop-in PPD replacement — so if either runs, **TDP silently fails**. They must be masked. See [Troubleshooting](#power-profiles-daemon--tuned-silent-tdp-failure).
4. **`systemctl enable` without `--now`** arms the service for next boot but never starts it in the current session, so it looks dead.

## Quick start (one-liner)

Run this on the handheld (in a terminal, so the prompts and reboot work):

```bash
curl -fsSL https://raw.githubusercontent.com/rgvxsthi/HHD-on-CachyOS/main/install.sh | bash
```

It downloads the project (including the `lib/` folder the scripts need) to `~/HHD-on-CachyOS` and runs `setup.sh`. Pass an action or flags after `-s --`:

```bash
# install + the in-Steam TDP slider
curl -fsSL https://raw.githubusercontent.com/rgvxsthi/HHD-on-CachyOS/main/install.sh | bash -s -- --steam-slider
# just run the health check
curl -fsSL https://raw.githubusercontent.com/rgvxsthi/HHD-on-CachyOS/main/install.sh | bash -s -- verify
# uninstall
curl -fsSL https://raw.githubusercontent.com/rgvxsthi/HHD-on-CachyOS/main/install.sh | bash -s -- uninstall
# repair a broken install (hhd won't start after a CachyOS update — see Troubleshooting)
curl -fsSL https://raw.githubusercontent.com/rgvxsthi/HHD-on-CachyOS/main/install.sh | bash -s -- fix
```

By default it fetches the latest tagged release; override with `HHD_REF=main` (branch/tag) or `HHD_DIR=/path` (install location). `HHD_NO_RUN=1` downloads without running.

## Quick start (git clone)

```bash
git clone https://github.com/rgvxsthi/HHD-on-CachyOS.git
cd HHD-on-CachyOS
chmod +x setup.sh verify.sh uninstall.sh
./setup.sh            # interactive; add --debug to trace every step
```

After the reboot:

```bash
./verify.sh           # read-only; add --debug for full trace
```

To reverse everything and restore the pre-install state:

```bash
./uninstall.sh        # removes HHD, unmasks PPD/InputPlumber, restores vendor stack
```

The scripts source [`lib/device-profile.sh`](lib/device-profile.sh) for device detection, so keep the `lib/` folder alongside them. They are interactive and idempotent, refuse to run as root, check your kernel and TDP interface before changing anything, ask before removing packages, and never reboot you without asking. They run under `bash`; if launched with `sh` they re-exec under `bash` automatically.

### Flags

- `--debug` (or `-debug`, `-d`): trace every command as it runs. Use this if something fails and you want to see exactly where.
- `--yes` (or `-y`): assume yes to prompts. Still asks before rebooting.
- `--steam-slider`: also install `steamos-manager-hhd` for the in-Steam TDP slider (AUR). See [that section](#optional-the-in-steam-tdp-slider-steamos--bazzite-feel).
- `--no-steam-slider`: skip the in-Steam TDP slider without asking.
- `--no-reboot`: never prompt to reboot.
- `--help` (or `-h`).

`uninstall.sh` adds two of its own:

- `--no-restore`: just remove HHD; do **not** unmask/reinstall InputPlumber, PPD, or the vendor stack.
- `--purge`: also delete `~/.config/hhd` (your profiles) and `~/hhd-setup-*.log`.

### Logging

Every run of the scripts writes a timestamped log to your home directory:

- `~/hhd-setup-<timestamp>.log`
- `~/hhd-verify-<timestamp>.log`
- `~/hhd-uninstall-<timestamp>.log`

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

# 4. mask power-profiles-daemon + tuned (they fight adjustor over TDP - see Troubleshooting)
sudo systemctl mask --now power-profiles-daemon.service
sudo systemctl mask --now tuned.service          # if present

# 5. ASUS ONLY: remove the ASUS userspace stack IF present (it fights adjustor)
pacman -Qs asusctl rog-control-center supergfxctl
#    LENOVO ONLY: install the acpi_call module for TDP instead
#    sudo pacman -S acpi_call-dkms

# 6. install the packages (Lenovo: add acpi_call-dkms)
sudo pacman -S hhd adjustor hhd-ui

# 7. enable AND start (the --now matters)
sudo systemctl enable --now hhd@$(whoami)

# 8. reboot
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

The `setup.sh` script detects and offers to remove these for you. **Lenovo Legion Go has no equivalent** — there is no Linux vendor daemon that fights adjustor, so the script skips this step on Lenovo.

### `power-profiles-daemon` / `tuned`: silent TDP failure

This one is device-agnostic (ASUS **and** Lenovo) and easy to miss because nothing errors — the TDP section just quietly does nothing.

adjustor drives the power profile directly **and** registers the PowerProfiles D-Bus names (`org.freedesktop.UPower.PowerProfiles` / `net.hadess.PowerProfiles`) — it is effectively a drop-in replacement for `power-profiles-daemon`. CachyOS ships PPD by default. If PPD (or `tuned`) is running, adjustor cannot own the bus name (and on ASUS also fights the `platform_profile` sysfs node), so it refuses to initialize TDP unless the `HHD_PPD_MASK` environment variable is set. On a manual CachyOS install it is not, so **you must mask them yourself**:

```bash
sudo systemctl mask --now power-profiles-daemon.service
sudo systemctl mask --now tuned.service    # only if present
```

**Mask, don't `pacman -R`.** Removal drags out the desktop power panels (GNOME/KDE) that depend on the PPD D-Bus API — which adjustor's own replacement then serves — and a plain `disable` can be reactivated via D-Bus/socket. `setup.sh` masks them for you; `uninstall.sh` unmasks and re-enables them.

### "Do I need to remove `steamos-manager`?"

**No — do not remove it.** `steamos-manager` is a Valve/SteamOS component; it is **not** in the CachyOS or Arch repos and **not** part of the CachyOS-Handheld image, so on a stock CachyOS install there is nothing to remove. The advice "remove steamos-manager for HHD" comes from SteamOS/Bazzite contexts and does not apply here. Neither script removes it.

### Optional: the in-Steam TDP slider (SteamOS / Bazzite feel)

Want the Deck-style TDP/GPU sliders inside **Steam's own performance menu** (Game Mode), on top of the HHD overlay? That comes from the HHD fork of steamos-manager, `steamos-manager-hhd-git` (AUR). It implements Valve's `SteamOSManager1` D-Bus API and shells out to HHD's `hhd.steamos` helper, so the Steam slider and the HHD overlay both drive **one** HHD backend — they coexist, the overlay is unaffected.

`setup.sh --steam-slider` installs and wires it up for you. It builds the package **directly from the AUR with `makepkg`** — no AUR helper (`paru`/`yay`) required; it installs `git`/`base-devel` and lets `makepkg -s` pull the rest from the official repos. What it does and what you must know:

- **Replaces stock `steamos-manager`** (`provides`+`conflicts`; can't co-install). Depends on `hhd >= 4.1`; builds from source (pulls `rust`/`clang`).
- **Nothing auto-enables** — the script runs `sudo systemctl enable --now steamos-manager.service` and `systemctl --user enable --now steamos-manager.service` (the user unit is the one Steam talks to; it must be enabled inside your desktop/graphical session).
- **Turn on "Enable TDP Controls" in the HHD app.** Without it the slider stays inert.
- **Game Mode only.** The slider lives in Steam's Deck performance menu in the gamescope session (CachyOS-Handheld `gamescope-session-plus@steam`), not desktop Big Picture.
- **Disable Decky TDP plugins** (SimpleDeckyTDP / PowerControl) — HHD reports a conflict and greys the slider out otherwise.
- Installs `acpi_call-dkms` if missing, because the slider writes explicit wattages through `acpi_call`.

Manual equivalent (direct AUR build, no helper):

```bash
sudo pacman -S --needed git base-devel
git clone https://aur.archlinux.org/steamos-manager-hhd-git.git
cd steamos-manager-hhd-git && makepkg -si
sudo systemctl enable --now steamos-manager.service
systemctl --user enable --now steamos-manager.service   # inside your desktop session
# then in the HHD app: Enable TDP Controls = ON
```

`uninstall.sh` disables the units and removes the package (leaving no steamos-manager, which is the CachyOS default). Unverified on CachyOS hardware; it is an AUR `-git` build, so it can lag Steam/HHD changes.

### Double controller / dead buttons: the `hid_asus` blacklist (ASUS only)

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

### Lenovo Legion Go: controllers and TDP

Legion differs from ASUS in two ways the scripts handle automatically:

- **TDP uses `acpi_call`, not `platform_profile`.** adjustor talks to the Lenovo GameZone WMI methods (`\_SB.GZFD.*`) through `/proc/acpi/call`, which needs the `acpi_call` kernel module. `setup.sh` installs `acpi_call-dkms` and loads it. If TDP is missing on Legion, check `lsmod | grep acpi_call` and that `/proc/acpi/call` exists.
- **Controllers need `xpad` bound.** The kernel must bind `xpad` to the pad, which HHD ships as a udev rule (`/usr/lib/udev/rules.d/83-hhd.rules`) — important for the Go S (VID `1a86` PID `e310`). If the controller is missing, confirm that rule is installed (it comes with the `hhd` package). Until the binding is mainlined, the Go tablet may also need the shipped rule or a kernel patch.
- **Blacklist the Legion controller HID driver (Linux 7.1+).** The mainline Legion Go controller driver (`hid_lenovo_go` / `hid_legion` — the name varies across kernels) fights HHD's controller emulation when both are active, so the pad **plug/unplugs in the gamescope session** — the Legion analogue of the ASUS double-controller case. `setup.sh` **discovers the actual module by pattern** (`legion|lenovo_go`, which deliberately excludes the unrelated `hid_lenovo` ThinkPad driver), and offers to blacklist whatever it finds (writes `/etc/modprobe.d/hhd-lenovo.conf` + rebuilds the initramfs); `uninstall.sh` removes it. On kernels older than 7.1 the module doesn't exist and there's nothing to blacklist. **Unverified on hardware** — based on a user report.

No Legion model hard-requires the Bazzite kernel (only the ROG Z13 2025 does). Legion Go 2 (`83N0`/`83N1`) specifics are **unconfirmed**.

### Wrong / scrambled buttons after install (e.g. reported on Ally X)

If face buttons work but the rest are scrambled (R2 dead, Start/Select dead, a shoulder opens the HHD overlay), HHD grabbed the pad but applied the **wrong button map** — usually wrong device detection, a stale HHD, or InputPlumber not fully removed. Run `./verify.sh` and paste the diagnostics block. First moves: update HHD (`sudo pacman -Syu hhd`), confirm InputPlumber is masked+gone and reboot, and check `cat /sys/class/dmi/id/product_name` matches your actual model. `asus_armoury` blacklisting does **not** fix this (it only breaks TDP); the only controller-related blacklist is the ASUS `hid_asus_ally` double-pad case above.

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

## Uninstalling

`uninstall.sh` reverses `setup.sh` for whatever device it detects:

- disables and stops `hhd@<user>`, removes `hhd`/`adjustor`/`hhd-ui` (and Lenovo's `acpi_call-dkms`, asked separately);
- unmasks and (with prompts) re-enables `power-profiles-daemon`/`tuned` and InputPlumber;
- ASUS: offers to reinstall the vendor stack and removes the `hid_asus_ally` blacklist file (rebuilding the initramfs); Lenovo: nothing vendor-specific to restore;
- if you installed the in-Steam slider, disables its units and removes `steamos-manager-hhd-git`;
- optionally deletes your HHD config and setup logs (`--purge`).

```bash
./uninstall.sh                 # interactive, restores original state
./uninstall.sh --no-restore    # strip HHD only, leave PPD/InputPlumber as the install left them
./uninstall.sh --purge --yes   # non-interactive full teardown incl. config + logs
```

## Troubleshooting

### hhd won't start after a CachyOS update (`ModuleNotFoundError: No module named 'pkg_resources'`)

**Symptom:** after a `pacman -Syu`, `hhd@<user>.service` never activates. `systemctl status hhd@<user>` shows `activating (auto-restart)` and the journal repeats:

```
File ".../site-packages/hhd/__main__.py", line 16, in <module>
    import pkg_resources
ModuleNotFoundError: No module named 'pkg_resources'
```

**Cause:** hhd's entrypoint uses `pkg_resources` (from `python-setuptools`) to discover its plugins. **setuptools ≥ 81 removed `pkg_resources`**, so once an update pulls a newer setuptools the module is gone and the daemon exits 1 on every start. This is upstream (hhd hasn't migrated off the deprecated module yet), not a fault of this installer. Downgrading setuptools does **not** help — the current packages don't ship `pkg_resources` at all.

**Fix** — installs a tiny `pkg_resources` compatibility shim (just the `iter_entry_points` hhd needs, backed by the standard-library `importlib.metadata`), then restarts hhd:

```bash
curl -fsSL https://raw.githubusercontent.com/rgvxsthi/HHD-on-CachyOS/main/fix-hhd.sh | bash
# or, if you cloned the repo:
./fix-hhd.sh
```

The shim is upstream-safe, needs no setuptools downgrade or package hold, and **survives hhd reinstalls and updates**. `setup.sh` also installs it automatically (step 6b), so a fresh `setup.sh` on an already-updated system comes up working. `uninstall.sh` removes the shim. Once an hhd update lands that no longer imports `pkg_resources`, the shim is harmless and can be deleted (`sudo rm -rf <site-packages>/pkg_resources`).

## Credits

- Handheld Daemon: https://github.com/hhd-dev/hhd
- CachyOS Handheld: https://github.com/CachyOS/CachyOS-Handheld
- asus-linux (g14 kernel, asusctl): https://asus-linux.org

## License

MIT. See [LICENSE](LICENSE).
