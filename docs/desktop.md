# Desktop

Lifeboat Desktop is a native app with a tray icon. No Docker, no container
runtime, no root. It runs the same control plane and the same
OpenAI-/Anthropic-compatible API as the container images, against a local
model file.

- [Which file do I download?](#which-file-do-i-download)
- [Windows](#windows)
- [macOS](#macos)
- [Linux](#linux)
- [First run](#first-run)
- [GPU acceleration](#gpu-acceleration)
- [Upgrading](#upgrading)
- [Uninstalling](#uninstalling)

---

## Which file do I download?

Everything is on the [latest release](../../releases/latest). The desktop
builds are cut **per platform**, so the newest version differs between them —
take the newest file for your platform rather than assuming one version number
covers all three.

| Platform | File |
|---|---|
| Windows 10/11 x64 | `Lifeboat-<version>-setup.exe` |
| macOS 13+, Apple Silicon | `Lifeboat-<version>-macos-arm64.dmg` |
| macOS 13+, Intel | `Lifeboat-<version>-macos-x86_64.dmg` |
| Debian / Ubuntu x64 | `lifeboat-desktop_<version>_amd64.deb` |
| Debian / Ubuntu arm64 | `lifeboat-desktop_<version>_arm64.deb` |
| Any Linux distro, x64 | `Lifeboat-<version>-linux-x86_64.tar.gz` |
| Any Linux distro, arm64 | `Lifeboat-<version>-linux-aarch64.tar.gz` |

---

## Windows

**`Lifeboat-<version>-setup.exe`** — a signed installer. Download it and
double-click.

```
Lifeboat-<version>-setup.exe
```

That is the whole procedure. Three things about it are worth knowing before
you run it:

* **It installs for you, not for the machine**, so there is **no
  administrator prompt**. Files go to
  `%LOCALAPPDATA%\Programs\Lifeboat` and your models and database to
  `%LOCALAPPDATA%\Lifeboat`. Nothing is written to `Program Files` and nothing
  needs elevation, at install time or afterwards.
* **Two checkboxes, and they are independent** — *Start Lifeboat when I sign
  in* and *Create a desktop shortcut*. Neither implies the other.
* **The installer is Authenticode-signed**, so SmartScreen has a publisher to
  show. If you still get a "Windows protected your PC" screen, click **More
  info** and confirm the publisher reads **Iterate.ai** before choosing **Run
  anyway**. If it does not, stop and email <support@iterate.ai>.

### Prerequisite: .NET 8 Desktop Runtime

The tray icon is a .NET application. The installer checks for the runtime and
warns you if it is absent, but it does not install it for you — without it the
app installs and then appears to do nothing when launched.

```powershell
winget install --id Microsoft.DotNet.DesktopRuntime.8 -e
```

or download it from
<https://dotnet.microsoft.com/download/dotnet/8.0/runtime>. `lifeboat-core.exe`
itself does **not** need .NET and runs headless without it.

### Requirements

| | |
|---|---|
| Windows | 10 build 17763 (1809) or newer, 64-bit |
| Runtime | .NET 8 Desktop Runtime (tray only) |
| GPU | optional — any NVIDIA, AMD or Intel GPU with a Vulkan driver |
| Disk | ~150 MB for the app, plus your models |

### The command line

The installer puts `lifeboat-core.exe` beside the tray application. It is the
server and the CLI both:

```powershell
& "$env:LOCALAPPDATA\Programs\Lifeboat\lifeboat-core.exe" doctor
& "$env:LOCALAPPDATA\Programs\Lifeboat\lifeboat-core.exe" run
```

`doctor` reports what the machine can actually do — GPU, memory, and the model
sizes that fit — and is the first thing to run if something is not working.

### If PowerShell rejects a `curl … | bash` line

It will. The Docker one-liner in the welcome email is for Linux hosts. On
Windows, `bash` does not exist and you get:

```
bash : The term 'bash' is not recognized as the name of a cmdlet...
```

That line is not the Windows install path. Use `setup.exe` above.

---

## macOS

**`Lifeboat-<version>-macos-arm64.dmg`** on Apple Silicon, or
`…-macos-x86_64.dmg` on Intel.

1. Open the `.dmg`.
2. Drag **Lifeboat** to **Applications**.
3. Eject the disk image and launch Lifeboat from Applications.

The build is signed with a Developer ID, **notarized by Apple and stapled**, so
it launches with no security warning — and because the notarization ticket
travels inside the file, that is true offline as well. You should not need to
right-click → Open, and you should never need `xattr -d`. If macOS refuses to
open it, the download is damaged or altered; fetch it again rather than working
around the warning.

**Lifeboat lives in the menu bar, not the Dock.** There is no Dock icon and no
window on launch — that is deliberate (`LSUIElement`). Look for the Lifeboat
icon in the menu bar at the top right.

### Requirements

| | |
|---|---|
| macOS | 13 Ventura or newer |
| Apple Silicon | GPU offload via Metal; MLX and GGUF models both run on the GPU |
| Intel | GGUF only, on the CPU — there is no Metal path for these models and no MLX |
| Disk | ~400 MB for the app, plus your models |

Apple Silicon is much the better machine for this: the GPU and the CPU share
memory, so a 16 GB Mac can hold a model a 16 GB discrete GPU could not.

---

## Linux

Two formats, same contents.

**Debian, Ubuntu and derivatives:**

```sh
sudo apt install ./lifeboat-desktop_<version>_amd64.deb
```

`apt install ./file.deb` rather than `dpkg -i` so the recommended packages —
the tray binding and the Vulkan loader — are pulled in. With `dpkg -i` you get
the app and none of them.

**Any other distribution** — the tarball unpacks to the same layout, rooted
at `/`:

```sh
sudo tar -C / -xzf Lifeboat-<version>-linux-x86_64.tar.gz
```

Either way you get `/opt/lifeboat` and two commands on `PATH`:

| | |
|---|---|
| `lifeboat-core` | the server and the CLI. Runs headless. |
| `lifeboat-tray` | the tray icon. Needs a desktop session. |

```sh
lifeboat-core doctor     # what this machine can run
lifeboat-core run        # start the server in the foreground
```

### Requirements

| | |
|---|---|
| glibc | **2.31 or newer** — Debian 11+, Ubuntu 20.04+, RHEL 9+ |
| Python | 3.10+ (the tray is a Python script; `lifeboat-core` is self-contained) |
| Tray | GTK 3 and an AppIndicator binding — `gir1.2-gtk-3.0`, `gir1.2-ayatanaappindicator3-0.1` |
| GPU | optional — `libvulkan1` plus your vendor's Vulkan driver |
| Disk | ~200 MB for the app, plus your models |

**On GNOME the tray needs AppIndicator**, and without it the icon does not
render and nothing reports an error. Install
`gir1.2-ayatanaappindicator3-0.1` (Debian/Ubuntu) or your distribution's
equivalent. None of this affects `lifeboat-core`, which is fully usable
headless with the web console.

### Running it as a service

The package does not install a systemd unit, because the desktop app is
session-scoped by design. For a machine that should serve on boot, a user unit
is enough:

```sh
mkdir -p ~/.config/systemd/user
cat > ~/.config/systemd/user/lifeboat.service <<'EOF'
[Unit]
Description=Lifeboat
After=network-online.target

[Service]
ExecStart=/usr/bin/lifeboat-core run
Restart=on-failure

[Install]
WantedBy=default.target
EOF
systemctl --user enable --now lifeboat
loginctl enable-linger "$USER"     # so it survives logout
```

For a headless server, prefer the [container images](docker.md) — they are
built for it and are what the Kubernetes chart deploys.

---

## First run

1. Open the console at <http://127.0.0.1:30800> — or use the tray menu's
   **Open Console**, which is the reliable route: a desktop app cannot insist
   on a port, so if something else already holds 30800 Lifeboat takes another
   one and the tray knows which.
2. **Create your administrator account.** Lifeboat ships with no credentials;
   the first visit asks you to choose an email and password, and that account
   is the superadmin.
3. **Models → Add Model.** Pick something that fits — the app filters the
   catalogue to what your machine can actually load and says why when it
   refuses something.
4. **Servers → New Server**, choose the model, press **Start**.
5. Point any OpenAI-compatible client at `http://127.0.0.1:30800/v1`.

Every install runs for 24 hours with no licence key, so you can get this far
before deciding anything.

---

## GPU acceleration

The desktop app uses **Vulkan** on Windows and Linux, and **Metal** on Apple
Silicon. Vulkan is one binary that offloads to NVIDIA, AMD and Intel alike,
which is why there is no separate CUDA download.

| Platform | GPU path | Covers |
|---|---|---|
| Windows | Vulkan | NVIDIA, AMD, Intel (including integrated) |
| Linux | Vulkan | NVIDIA, AMD, Intel (including integrated) |
| macOS, Apple Silicon | Metal | the built-in GPU |
| macOS, Intel | none | CPU only |

The GPU backend is loaded at runtime, so a machine with no Vulkan driver or no
capable GPU simply uses the CPU — nothing fails, it is just slower. On Linux
the loader is a *recommended* package rather than a required one for exactly
this reason; install `libvulkan1` and your vendor's driver
(`mesa-vulkan-drivers` covers AMD and Intel; NVIDIA's own driver includes it)
if `lifeboat-core doctor` reports no GPU and you expect one.

**NPUs and Intel XPU are not used.** An "AI PC" NPU is idle under Lifeboat:
there is no inference path to it here, and because it shares system memory it
would not raise the ceiling that actually limits decode speed anyway.

### What limits speed

Decode is bound by **memory bandwidth**, not core count, so a bigger GPU helps
mainly by having faster memory and by fitting the model at all. As a rule of
thumb on a machine with 8 GB: a 1.5B–4B model at 4-bit is comfortable, 8B is
the ceiling, and 14B will not fit. `lifeboat-core doctor` computes this for
your actual machine, including a container memory limit if there is one.

---

## Upgrading

| Platform | How |
|---|---|
| Windows | run the new `setup.exe` over the top; it replaces the app and keeps `%LOCALAPPDATA%\Lifeboat` |
| macOS | quit from the menu bar, then drag the new app over the old one |
| Linux (deb) | `sudo apt install ./lifeboat-desktop_<new>_amd64.deb` |
| Linux (tar) | `sudo tar -C / -xzf` the new tarball over the old one |

Models, settings and the database live outside the application directory in
every case, so an upgrade never touches them.

---

## Uninstalling

**Windows** — *Settings → Apps → Lifeboat → Uninstall*. The uninstaller asks
separately whether to delete `%LOCALAPPDATA%\Lifeboat`; answer **No** to keep
your downloaded models.

**macOS** — quit from the menu bar and drag the app to the Trash. Application
data is under `~/Library/Application Support/Lifeboat`.

**Linux** — `sudo apt remove lifeboat-desktop`, or delete `/opt/lifeboat` and
the two symlinks if you installed the tarball. Models stay in
`~/.local/share/lifeboat` either way.

In all three cases the model files are deliberately left behind: they are
often tens of gigabytes and an uninstaller that silently discards them is not
a favour.

---

## Verifying a download

macOS and Windows builds are code-signed, so the operating system checks them
for you — that is the stronger check and you do not need to do anything else.

Linux builds are not signed. Where a release publishes a `SHA256SUMS` file,
check against it:

```sh
sha256sum -c SHA256SUMS --ignore-missing
```

---

## Getting help

Run `lifeboat-core doctor` first and include its output — it reports the
platform, the GPU, the memory and the engine that was selected, which is most
of what any answer depends on.

* Download or install problems — open an issue on this repository.
* Anything touching your licence, your data or your account — email
  <support@iterate.ai>.
