# HHD on CachyOS — ASUS ROG Ally & Lenovo Legion Go

Get **Handheld Daemon (HHD)** working properly on CachyOS — TDP, fan control, RGB, and the vendor menu buttons — with guided, logged scripts that **auto-detect your device** and apply the right fixes.

> **Tested on:** CachyOS (Handheld Edition), **ASUS ROG Ally Z1 Extreme**, kernel `7.0.12-1-cachyos-deckify`. Anything **6.19+** should work (that's where the `asus-armoury` TDP driver went mainline).
>
> **Lenovo Legion Go** support is derived from HHD's own source and is **unverified on real hardware** — best-effort until someone confirms. See [Supported devices](#supported-devices).

---

## Contents

- [What you get](#what-you-get)
- [Will this work for me? (Supported devices)](#supported-devices)
- [Quick start](#quick-start) — the one command most people need
- [What the script actually does](#what-the-script-actually-does)
- [After install: configure it](#after-install-configure-it)
- [Check it's working](#check-its-working)
- [Flags, logging & uninstall](#flags--logging)
- [Troubleshooting](#troubleshooting) — start here if something's broken
- [Optional: the in-Steam TDP slider](#optional-the-in-steam-tdp-slider)
- [Manual install (by hand)](#manual-install-by-hand)
- [Reference: the "use the Bazzite kernel" myth](#the-use-the-bazzite-kernel-myth)

---

## What you get

A fresh HHD install "by the generic Arch instructions" on CachyOS leaves you with **no TDP slider** and **dead vendor buttons**. These scripts fix that:

- ✅ **TDP / power limits** working (per-preset and custom wattage)
- ✅ **Fan curves, RGB, battery charge limit** via the HHD app + overlay
- ✅ **Vendor menu buttons** and controller handled cleanly
- ✅ **Auto-detects** ASUS ROG Ally vs Lenovo Legion Go and applies the right steps
- ✅ **Reversible** — a matching uninstaller restores your pre-install state
- ✅ **Safe** — interactive, idempotent, refuses to run as root, never reboots without asking, writes a full log every run

Three scripts, one job each:

| Script | Does | Changes your system? |
|---|---|---|
| `setup.sh` | Install + configure HHD | Yes (asks first) |
| `verify.sh` | Health check | No (read-only) |
| `uninstall.sh` | Reverse everything | Yes (asks first) |
| `fix-hhd.sh` | Repair a broken HHD after a CachyOS update | Yes (small, targeted) |

---

## Supported devices

The device is matched from DMI `product_name` in [`lib/device-profile.sh`](lib/device-profile.sh).

| Family | Models | TDP path | Controller note |
|---|---|---|---|
| **ASUS ROG Ally** | Ally / Ally X / ROG Xbox Ally | `asus_wmi` + `asus_armoury` → `platform_profile` | optional `hid_asus_ally` blacklist (only in the [double-pad case](#double-controller--dead-buttons-asus)) |
| **Lenovo Legion Go** | Go (83E1), Go 2 (83N0/83N1), Go S (83L3/83N6/83Q2/83Q3) | `acpi_call` module → `/proc/acpi/call` | `xpad` bound via HHD udev rule; Linux 7.1+ offers to blacklist `hid_lenovo_go` |

**Both families also get:** InputPlumber removal, `power-profiles-daemon`/`tuned` masking, and the `hhd` + `hhd-ui` install. **Lenovo additionally** installs `acpi_call-dkms` (its TDP interface). An unrecognized device still gets the shared steps, with a warning.

Vendor userspace removed on ASUS: `asusctl`, `rog-control-center`, `supergfxctl`, `asusd`. Lenovo has no equivalent daemon, so that step is skipped.

---

## Quick start

Run this **on the handheld, in a terminal** (so prompts and the reboot work):

```bash
curl -fsSL https://raw.githubusercontent.com/rgvxsthi/HHD-on-CachyOS/main/install.sh | bash
```

That downloads the project (including the `lib/` folder the scripts need) to `~/HHD-on-CachyOS` and runs `setup.sh`. After it reboots you, you're done.

### Other actions

Add an action after `-s --`:

```bash
# install + the in-Steam TDP slider
curl -fsSL https://raw.githubusercontent.com/rgvxsthi/HHD-on-CachyOS/main/install.sh | bash -s -- --steam-slider

# just run the health check
curl -fsSL https://raw.githubusercontent.com/rgvxsthi/HHD-on-CachyOS/main/install.sh | bash -s -- verify

# uninstall
curl -fsSL https://raw.githubusercontent.com/rgvxsthi/HHD-on-CachyOS/main/install.sh | bash -s -- uninstall

# repair a broken install (hhd won't start after a CachyOS update)
curl -fsSL https://raw.githubusercontent.com/rgvxsthi/HHD-on-CachyOS/main/install.sh | bash -s -- fix
```

**Environment overrides:** `HHD_REF=main` (branch/tag to fetch), `HHD_DIR=/path` (install location), `HHD_NO_RUN=1` (download only, don't run).

### Prefer git clone?

```bash
git clone https://github.com/rgvxsthi/HHD-on-CachyOS.git
cd HHD-on-CachyOS
chmod +x setup.sh verify.sh uninstall.sh
./setup.sh            # interactive; add --debug to trace every step
```

Keep the `lib/` folder next to the scripts — they source [`lib/device-profile.sh`](lib/device-profile.sh) for detection.

---

## What the script actually does

The generic Arch instructions miss four CachyOS-specific things. Here's each problem and how `setup.sh` handles it:

| # | The problem | The fix |
|---|---|---|
| 1 | **TDP is a separate piece.** `hhd` does controllers/RGB/overlay; TDP + fans come from `adjustor` (merged into `hhd` as of v4). Lenovo also needs the `acpi_call` kernel module. | Installs `hhd` + `hhd-ui` (+ `acpi_call-dkms` on Lenovo). |
| 2 | **CachyOS ships InputPlumber**, which fights HHD over the controller. A plain `disable` doesn't stick — it's D-Bus activated and relaunches. | Masks + removes it, then reboots. |
| 3 | **`power-profiles-daemon` / `tuned` fight adjustor** over the power profile → **TDP silently fails**. | Masks both. See [details](#tdp-does-nothing-power-profiles-daemon--tuned). |
| 4 | **`systemctl enable` without `--now`** arms for next boot but never starts it now → looks dead. | Uses `enable --now`. |

Every run writes a timestamped log and prints a `BEGIN HHD DIAGNOSTICS … END` block — paste that when asking for help.

---

## After install: configure it

Two places to change settings, depending on which mode you're in:

- **Desktop mode (KDE Plasma):** open the **Handheld Daemon** app from your launcher. TDP slider, fan curves, RGB, button bindings — all there.
- **Game Mode (gamescope):** double-tap the small menu button next to the screen for the overlay.

> **The overlay "errors" that aren't errors.** In the **desktop** journal you'll see a wall of `OVRL` D-Bus/GL errors ending in `Overlay thread died`. **This is expected.** The overlay is a *gamescope* overlay and only renders inside Game Mode; in desktop it has nothing to attach to, so it exits. Use the desktop app there. The overlay works fine in Game Mode.

---

## Check it's working

After the reboot:

```bash
./verify.sh           # read-only health check; add --debug for full trace
```

Or by hand:

```bash
systemctl is-active hhd@$(whoami)                 # want: active
sudo journalctl -u hhd@$(whoami) -b --no-pager | grep -iE 'adjustor|asus|profile'
```

A healthy log shows the adjustor ASUS backend loading and setting the profile:

```
- adjustor: adjustor_asus, adjustor_init, adjustor_battery, adjustor_ppd
ADJA  INFO   Setting thermal profile to '0'
AGPU  INFO   Handling energy settings for power profile 'balanced'.
```

`adjustor_asus` + `Setting thermal profile` = TDP is working.

### Worth checking once it works

- [ ] **Gyro** in Steam controller settings (only exposed in **DualSense** emulation mode, not Xbox)
- [ ] **Sleep & wake** — suspend, wake, confirm controller works and battery didn't drain (most common Ally pain point; usually firmware if broken)
- [ ] **BIOS / MCU firmware** — `sudo dmidecode -s bios-version` vs ASUS's support page (Linux can't update Ally firmware cleanly)
- [ ] **Battery charge limit** — cap at 80% in the HHD app if it lives on the charger
- [ ] **AC vs battery TDP profiles** and a **fan curve** in the HHD app
- [ ] **Back paddles (M1/M2)** — bound in HHD's Controller section (do nothing until mapped)

---

## Flags & logging

**`setup.sh` / `verify.sh`:**

| Flag | Effect |
|---|---|
| `--debug` (`-d`) | Trace every command — use when something fails |
| `--yes` (`-y`) | Assume yes to prompts (still asks before rebooting) |
| `--steam-slider` | Also install the [in-Steam TDP slider](#optional-the-in-steam-tdp-slider) |
| `--no-steam-slider` | Skip the slider without asking |
| `--no-reboot` | Never prompt to reboot |
| `--help` (`-h`) | Show help |

**`uninstall.sh` adds:**

| Flag | Effect |
|---|---|
| `--no-restore` | Remove HHD only; leave PPD/InputPlumber/vendor stack as the install left them |
| `--purge` | Also delete `~/.config/hhd` (your profiles) and `~/hhd-setup-*.log` |

**Logs** (colour stripped so they stay readable):

- `~/hhd-setup-<timestamp>.log`
- `~/hhd-verify-<timestamp>.log`
- `~/hhd-uninstall-<timestamp>.log`

### Uninstalling

`uninstall.sh` reverses `setup.sh` for whatever device it detects:

- Disables/stops `hhd@<user>`, removes `hhd`/`adjustor`/`hhd-ui` (and Lenovo's `acpi_call-dkms`, asked separately)
- Unmasks and (with prompts) re-enables `power-profiles-daemon`/`tuned` and InputPlumber
- **ASUS:** offers to reinstall the vendor stack, removes the `hid_asus_ally` blacklist (rebuilds initramfs). **Lenovo:** nothing vendor-specific
- If you installed the in-Steam slider, disables its units and removes it
- With `--purge`, deletes your HHD config + setup logs

```bash
./uninstall.sh                 # interactive, restores original state
./uninstall.sh --no-restore    # strip HHD only
./uninstall.sh --purge --yes   # non-interactive full teardown incl. config + logs
```

---

## Troubleshooting

**Start here.** Find your symptom, then open the section.

| Symptom | Section |
|---|---|
| hhd won't start after a `pacman -Syu` (`No module named 'pkg_resources'`) | [→](#hhd-wont-start-after-an-update-pkg_resources) |
| TDP section does nothing / silently fails | [→](#tdp-does-nothing-power-profiles-daemon--tuned) |
| Installed asusctl / rog-control-center too | [→](#i-also-installed-asusctl--rog-control-center) |
| "Should I remove steamos-manager?" | [→](#should-i-remove-steamos-manager) |
| Two controllers in Steam / double or dead input (ASUS) | [→](#double-controller--dead-buttons-asus) |
| Buttons scrambled after install (e.g. Ally X) | [→](#scrambled-buttons-after-install) |
| Lenovo controllers or TDP missing | [→](#lenovo-legion-go-controllers--tdp) |
| Not sure TDP is actually changing | [→](#verifying-tdp-actually-changes) |

---

### hhd won't start after an update (`pkg_resources`)

**Symptom:** after a `pacman -Syu`, `hhd@<user>.service` never activates. `systemctl status` shows `activating (auto-restart)` and the journal repeats:

```
File ".../site-packages/hhd/__main__.py", line 16, in <module>
    import pkg_resources
ModuleNotFoundError: No module named 'pkg_resources'
```

**Cause:** hhd's entrypoint uses `pkg_resources` (from `python-setuptools`) to discover plugins. **setuptools ≥ 81 removed `pkg_resources`**, so once an update pulls a newer setuptools the module is gone and the daemon exits 1 on every start. This is upstream, not this installer's fault. **Downgrading setuptools does *not* help** — current packages don't ship `pkg_resources` at all.

**Fix** — installs a tiny `pkg_resources` shim (just the `iter_entry_points` hhd needs, backed by stdlib `importlib.metadata`), then restarts hhd:

```bash
curl -fsSL https://raw.githubusercontent.com/rgvxsthi/HHD-on-CachyOS/main/fix-hhd.sh | bash
# or, if you cloned the repo:
./fix-hhd.sh
```

The shim is upstream-safe, needs no downgrade or package hold, and **survives hhd reinstalls/updates**. `setup.sh` installs it automatically too (step 6b), so a fresh setup on an already-updated system comes up working. `uninstall.sh` removes it. Once an hhd release lands that no longer imports `pkg_resources`, the shim is harmless and can be deleted (`sudo rm -rf <site-packages>/pkg_resources`).

---

### TDP does nothing (`power-profiles-daemon` / `tuned`)

Device-agnostic (ASUS **and** Lenovo) and easy to miss — nothing errors, the TDP section just quietly does nothing.

**Why:** adjustor drives the power profile directly **and** registers the PowerProfiles D-Bus names — it's a drop-in replacement for `power-profiles-daemon`. CachyOS ships PPD by default. If PPD (or `tuned`) runs, adjustor can't own the bus name (and on ASUS also fights the `platform_profile` sysfs node), so it refuses to init TDP unless `HHD_PPD_MASK` is set — which it isn't on a manual install. **Mask them yourself:**

```bash
sudo systemctl mask --now power-profiles-daemon.service
sudo systemctl mask --now tuned.service    # only if present
```

> **Mask, don't `pacman -R`.** Removal drags out the desktop power panels (GNOME/KDE) that depend on the PPD D-Bus API — which adjustor's replacement then serves — and a plain `disable` can be reactivated via D-Bus/socket. `setup.sh` masks; `uninstall.sh` unmasks and re-enables.

---

### I also installed asusctl / rog-control-center

Remove them, or at least make sure `asusd` isn't running. asusctl/rog-control-center and HHD's `adjustor` both drive the same ASUS power interface, so both running = they fight over TDP. `asusd` also auto-starts from a udev rule when the keyboard driver loads, so "installed but not enabled" can still mean it's running.

```bash
sudo systemctl disable --now asusd
sudo pacman -R rog-control-center asusctl supergfxctl   # remove only what's installed
```

`setup.sh` detects and offers to remove these. **Lenovo has no equivalent** — no vendor daemon fights adjustor, so the script skips this on Lenovo.

---

### Should I remove steamos-manager?

**No — don't.** `steamos-manager` is a Valve/SteamOS component, **not** in the CachyOS/Arch repos and **not** in the CachyOS-Handheld image, so on a stock CachyOS install there's nothing to remove. The "remove steamos-manager for HHD" advice comes from SteamOS/Bazzite and doesn't apply here. Neither script touches it.

(If you *want* the Steam performance-menu slider, that's a separate optional install — see [the in-Steam TDP slider](#optional-the-in-steam-tdp-slider).)

---

### Double controller / dead buttons (ASUS)

Some users on **other CachyOS kernels** report HHD not fully taking over the controller, needing the native ASUS HID drivers blacklisted. **Only do this if you actually have the symptom.**

**The symptom:** open **Steam → Settings → Controller**. If you see **two** controllers — the HHD-emulated one (e.g. an Xbox 360 pad) **plus** a separate "ROG Ally" — the native HID driver is leaking a second pad and you get double input. **One** controller = you don't need this, and applying it can break input.

**Fix (only in the two-controller case):**

```bash
echo 'blacklist hid_asus_ally' | sudo tee /etc/modprobe.d/hhd-ally.conf
echo 'blacklist hid_asus'      | sudo tee -a /etc/modprobe.d/hhd-ally.conf
sudo mkinitcpio -P
sudo reboot
```

> **Known-good baseline (no blacklist):** on `7.0.12-1-cachyos-deckify` with `hid_asus_ally` and `asus_armoury` loaded, Steam shows a single emulated controller and HHD grabs the raw pad cleanly (removing InputPlumber is part of why). Whether you hit the double-pad case depends on your kernel flavour. Run `verify.sh` — it enumerates your controllers and tells you whether to check.

---

### Scrambled buttons after install

Reported on Ally X. Face buttons work but the rest is scrambled (R2 dead, Start/Select dead, a shoulder opens the overlay) → HHD grabbed the pad but applied the **wrong button map** — usually wrong device detection, a stale HHD, or InputPlumber not fully removed.

First moves:

1. Run `./verify.sh` and keep the diagnostics block.
2. Update HHD: `sudo pacman -Syu hhd`
3. Confirm InputPlumber is masked + gone, then reboot.
4. Check `cat /sys/class/dmi/id/product_name` matches your actual model.

> `asus_armoury` blacklisting does **not** fix this (it only breaks TDP). The only controller-related blacklist is the ASUS [double-pad case](#double-controller--dead-buttons-asus) above.

---

### Lenovo Legion Go: controllers & TDP

Legion differs from ASUS in two ways the scripts handle automatically:

- **TDP uses `acpi_call`, not `platform_profile`.** adjustor talks to the Lenovo GameZone WMI methods (`\_SB.GZFD.*`) through `/proc/acpi/call`, needing the `acpi_call` module. `setup.sh` installs `acpi_call-dkms` and loads it. If TDP is missing, check `lsmod | grep acpi_call` and that `/proc/acpi/call` exists.
- **Controllers need `xpad` bound.** HHD ships a udev rule (`/usr/lib/udev/rules.d/83-hhd.rules`) — important for the Go S (VID `1a86` PID `e310`). If the controller is missing, confirm that rule is installed (comes with the `hhd` package).
- **Blacklist the Legion controller HID driver (Linux 7.1+).** The mainline driver (`hid_lenovo_go` / `hid_legion` — name varies) fights HHD's emulation, so the pad **plug/unplugs in gamescope** (the Legion analogue of the ASUS double-pad case). `setup.sh` discovers the actual module by pattern (`legion|lenovo_go`, deliberately excluding the unrelated `hid_lenovo` ThinkPad driver) and offers to blacklist it (`/etc/modprobe.d/hhd-lenovo.conf` + initramfs rebuild); `uninstall.sh` removes it. Older kernels don't have the module — nothing to do.

> No Legion model hard-requires the Bazzite kernel (only the ROG Z13 2025 does). Legion Go 2 (`83N0`/`83N1`) specifics are **unconfirmed**. All Lenovo behaviour here is **unverified on hardware** — based on a user report.

---

### Verifying TDP actually changes

HHD controls TDP two ways that look different from the terminal:

- **Presets** (silent/balanced/performance/turbo) set the ASUS *thermal profile*; firmware applies that profile's built-in PPT limits. The `/sys/devices/platform/asus-nb-wmi/ppt_*` files do **not** change here — so watching them on a preset wrongly looks like nothing's happening.
- **Custom** writes explicit watts to those `ppt_*` files, so they *do* change as you drag the slider.

The reliable oracle for both is `ryzenadj`, which reads limits straight from the SMU. It needs the `ryzen_smu` module (without it, it falls back to `/dev/mem` and reads nothing):

```bash
paru -S ryzen_smu-dkms        # or: sudo pacman -S ryzen_smu-dkms
sudo modprobe ryzen_smu
sudo ryzenadj -i | grep -iE 'STAPM|PPT LIMIT'
```

Switch presets and re-run. `STAPM LIMIT` and `PPT LIMIT FAST/SLOW` should change per preset (higher on turbo than performance). `STAPM VALUE` is live draw and only climbs under load.

> The `asus-armoury` firmware-attributes (`/sys/class/firmware-attributes/asus-armoury/attributes/ppt_*/current_value`) are a separate BIOS-level mirror and won't track adjustor's writes — don't use them to judge whether TDP works.

---

## Optional: the in-Steam TDP slider

Want the Deck-style TDP/GPU sliders inside **Steam's own performance menu** (Game Mode), on top of the HHD overlay? That's the HHD fork of steamos-manager, `steamos-manager-hhd-git` (AUR). It implements Valve's `SteamOSManager1` D-Bus API and shells out to HHD's `hhd.steamos` helper, so the Steam slider and the HHD overlay drive **one** HHD backend — they coexist.

**`setup.sh --steam-slider` installs and wires it up for you.** It builds directly from the AUR with `makepkg` — no AUR helper needed (installs `git`/`base-devel`, lets `makepkg -s` pull the rest).

What to know:

- **Replaces stock `steamos-manager`** (`provides`+`conflicts`, can't co-install). Depends on `hhd >= 4.1`; builds from source (pulls `rust`/`clang`).
- **Nothing auto-enables** — the script enables both the system unit and the `--user` unit (the user unit is what Steam talks to; must be enabled inside your graphical session).
- **Turn on "Enable TDP Controls" in the HHD app** — without it the slider stays inert.
- **Game Mode only** — it's in Steam's Deck performance menu in the gamescope session, not desktop Big Picture.
- **Disable Decky TDP plugins** (SimpleDeckyTDP / PowerControl) — HHD greys the slider out on conflict.
- Installs `acpi_call-dkms` if missing (the slider writes explicit wattages through `acpi_call`).

<details>
<summary><strong>Manual equivalent (direct AUR build, no helper)</strong></summary>

```bash
sudo pacman -S --needed git base-devel
git clone https://aur.archlinux.org/steamos-manager-hhd-git.git
cd steamos-manager-hhd-git && makepkg -si
sudo systemctl enable --now steamos-manager.service
systemctl --user enable --now steamos-manager.service   # inside your desktop session
# then in the HHD app: Enable TDP Controls = ON
```

</details>

`uninstall.sh` disables the units and removes the package. **Unverified on CachyOS hardware**; it's an AUR `-git` build, so it can lag Steam/HHD changes.

---

## Manual install (by hand)

Prefer to do it yourself, or want to see exactly what the script does?

<details>
<summary><strong>Step-by-step manual install</strong></summary>

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

# 4. mask power-profiles-daemon + tuned (they fight adjustor over TDP)
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

Then verify with the commands under [Check it's working](#check-its-working).

</details>

---

## The "use the Bazzite kernel" myth

You'll see this advice everywhere. It **doesn't apply cleanly to CachyOS**:

- The Bazzite kernel is a Fedora/rpm kernel for an immutable OSTree system — no clean way to install it on an Arch-based distro like CachyOS.
- For the Ally, the power drivers (`asus-wmi` / `asus-armoury`) are mainline as of 6.19, so a current CachyOS kernel already has them. The Ally/Ally X are **not** on HHD's list of devices that hard-require Bazzite — only the Z13 (2025) is.
- The only genuinely kernel-dependent piece is **gyro** (the `bmi260` IMU). Test it in Steam controller settings. If it works, you're done. If dead and you want it, the Arch-native fix is the **OGC / `linux-g14`** kernel from asus-linux's g14 repo — **not** Bazzite. (Gyro is only exposed in **DualSense** emulation mode, not Xbox.)

---

## Credits

- **Handheld Daemon** — https://github.com/hhd-dev/hhd
- **CachyOS Handheld** — https://github.com/CachyOS/CachyOS-Handheld
- **asus-linux** (g14 kernel, asusctl) — https://asus-linux.org

## License

MIT. See [LICENSE](LICENSE).
