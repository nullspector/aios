# AIOS — Installable AI Developer OS Layer
## Complete Build & Deployment Guide  |  v0.3.0

---

## What You're Getting

AIOS installs as a **Linux system layer** on top of Ubuntu or Arch. After running `./install.sh`:

```
aios start    →  backend + dashboard live at localhost:7860
aios stop     →  shutdown gracefully
aios status   →  what's running (backend, docker, GPU)
aios doctor   →  full environment health check
aios new ...  →  create AI projects
aios gpu      →  GPU utilisation live view
```

---

## Project Structure After Install

```
/opt/aios/                    ← install root (AIOS_INSTALL_DIR)
├── backend/
│   ├── app/
│   │   ├── main.py           ← FastAPI app factory
│   │   ├── routes/           ← metrics, containers, run, system
│   │   ├── services/         ← system, gpu, docker, project, jupyter
│   │   └── utils/            ← shell.py, parser.py
│   ├── requirements.txt
│   └── run.py
├── cli/
│   ├── aios.py               ← Main CLI entrypoint (Typer)
│   └── aios_cli/
│       ├── _utils.py
│       ├── __init__.py
│       └── commands/
│           └── service.py    ← start/stop/restart/status/logs
├── dashboard/
│   └── index.html            ← Served at localhost:7860
└── venv/                     ← Python virtualenv

/usr/local/bin/aios           ← Global bash wrapper (auto-generated)
/etc/systemd/system/
└── aios-backend.service      ← Systemd unit (auto-start on boot)
/var/log/aios/
└── backend.log               ← Persistent logs
~/aios-projects/              ← Your AI projects
```

---

## Phase 1 — Installation

### Quick Install (one-liner)
```bash
git clone https://github.com/yourname/aios && cd aios && ./install.sh
```

### Environment Variables (override defaults)
```bash
AIOS_PORT=8080         ./install.sh   # different port
AIOS_NO_GPU=1          ./install.sh   # skip GPU/CUDA steps
AIOS_NO_DOCKER=1       ./install.sh   # skip Docker install
AIOS_INSTALL_DIR=/home/user/.aios ./install.sh  # custom path
```

### What install.sh does (step by step)

| Phase | Action |
|-------|--------|
| 0 | Detect OS (Ubuntu/Arch), detect NVIDIA GPU, detect systemd |
| 1 | Install: git, curl, build tools, Python 3.10+, pip, venv |
| 1 | Install: Docker CE, docker-compose |
| 2 | Install: nvidia-container-toolkit (if NVIDIA GPU detected) |
| 3 | Copy repo to /opt/aios, create Python venv, install deps |
| 4 | Write /usr/local/bin/aios bash wrapper |
| 5 | Write + enable systemd unit (aios-backend.service) |
| 6 | Run health check, offer to launch now |

---

## Phase 2 — System Service

### systemd service control
```bash
sudo systemctl start   aios-backend   # start
sudo systemctl stop    aios-backend   # stop
sudo systemctl restart aios-backend   # restart
sudo systemctl status  aios-backend   # status
sudo systemctl enable  aios-backend   # enable auto-start on boot
sudo systemctl disable aios-backend   # disable auto-start
journalctl -u aios-backend -f         # live logs
```

### aios CLI lifecycle commands
```bash
aios start             # start backend + open browser
aios start --no-browser  # start without opening browser
aios start --port 8080   # use custom port
aios stop              # stop gracefully
aios restart           # restart
aios status            # show backend/docker/GPU status
aios logs              # stream logs (journald or file)
aios logs -n 100       # last 100 lines
aios logs --no-follow  # dump and exit
```

---

## Phase 3 — Dashboard Auto-Start

The dashboard (`dashboard/index.html`) is served **by the FastAPI backend** as a static
mount at `/`. So starting the backend = serving the dashboard:

```
http://localhost:7860   →  dashboard (HTML/CSS/JS)
http://localhost:7860/api/metrics  →  JSON metrics
http://localhost:7860/docs  →  Swagger UI
```

`aios start` opens the dashboard in your browser automatically via `xdg-open`
(Linux with desktop) or `open` (macOS). Set `--no-browser` to skip this.

### Optional: Nginx reverse proxy (for remote access or HTTPS)
```nginx
# /etc/nginx/sites-available/aios
server {
    listen 80;
    server_name aios.local;

    location / {
        proxy_pass http://127.0.0.1:7860;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
    }
}
```
```bash
sudo ln -s /etc/nginx/sites-available/aios /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx
```

---

## Phase 4 — Project Structure Changes

### Files added by this build
```
install.sh                     ← Main installer (this phase)
aios-backend.service           ← systemd unit
cli/aios_cli/commands/
└── service.py                 ← start/stop/status/logs/restart
cli/aios.py                    ← Updated: service commands wired in
```

### Files you must update in your existing repo
| File | Change |
|------|--------|
| `backend/requirements.txt` | Ensure fastapi, uvicorn[standard], psutil are pinned |
| `cli/aios_cli/__init__.py` | No change needed |
| `cli/aios_cli/commands/__init__.py` | Create empty file |
| `.gitignore` | Add `venv/`, `*.pyc`, `__pycache__/` |

### Permissions handled by install.sh
- `/opt/aios` — owned by the installing user
- `/var/log/aios` — owned by the installing user  
- `/usr/local/bin/aios` — root-owned, world-executable
- `/etc/systemd/system/aios-backend.service` — root-owned

---

## Phase 5 — Advanced: Custom Linux ISO (Reference Guide)

> **This is advanced. Only do this if you want a bootable AIOS USB/ISO.**
> AIOS works perfectly as a system layer without this step.

### Option A: Ubuntu-based ISO with `debootstrap` + `grub`

**Concept:** Build a minimal Ubuntu filesystem, install AIOS into it, then
wrap it in an ISO using `xorriso`.

```bash
# 1. Install tools on your build machine
sudo apt install debootstrap squashfs-tools xorriso grub-pc-bin grub-efi-amd64-bin

# 2. Bootstrap a minimal Ubuntu system
sudo debootstrap --arch=amd64 jammy /tmp/aios-rootfs \
    http://archive.ubuntu.com/ubuntu

# 3. Chroot in and configure
sudo chroot /tmp/aios-rootfs /bin/bash <<'CHROOT'
apt-get update
apt-get install -y linux-image-generic live-boot systemd-sysv
# Run AIOS installer inside the chroot
AIOS_NO_DOCKER=0 /opt/aios/install.sh
systemctl enable aios-backend
CHROOT

# 4. Create squashfs
sudo mksquashfs /tmp/aios-rootfs /tmp/aios.squashfs -comp xz

# 5. Build ISO (simplified — real ISO needs EFI + GRUB config)
# Use a tool like 'cubic' (Ubuntu) for a GUI approach:
#   sudo apt install cubic && cubic
```

**Recommended tools for Ubuntu ISO:**
- [`cubic`](https://launchpad.net/cubic) — GUI ISO customizer (easiest)
- `live-build` — Debian official live ISO build tool
- `debootstrap` + `xorriso` — fully scripted, maximum control

### Option B: Arch Linux ISO with `archiso`

```bash
# 1. Install archiso (on an Arch machine)
sudo pacman -S archiso

# 2. Copy the baseline profile
cp -r /usr/share/archiso/configs/releng/ ~/aios-iso/

# 3. Add AIOS packages to packages.x86_64
echo "python" >> ~/aios-iso/packages.x86_64
echo "docker" >> ~/aios-iso/packages.x86_64
echo "nvidia-container-toolkit" >> ~/aios-iso/packages.x86_64  # if GPU

# 4. Add AIOS installer to airootfs
mkdir -p ~/aios-iso/airootfs/opt/aios
cp -r /path/to/aios-repo/* ~/aios-iso/airootfs/opt/aios/

# 5. Add a systemd service to auto-run install on first boot
cat > ~/aios-iso/airootfs/etc/systemd/system/aios-firstboot.service <<'SVC'
[Unit]
Description=AIOS First Boot Setup
After=network.target
ConditionPathExists=!/etc/aios-installed

[Service]
Type=oneshot
ExecStart=/opt/aios/install.sh
ExecStartPost=/bin/touch /etc/aios-installed
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SVC

# 6. Enable in airootfs
mkdir -p ~/aios-iso/airootfs/etc/systemd/system/multi-user.target.wants/
ln -s /etc/systemd/system/aios-firstboot.service \
    ~/aios-iso/airootfs/etc/systemd/system/multi-user.target.wants/

# 7. Build the ISO
sudo mkarchiso -v -w /tmp/archiso-work -o ~/aios-iso/out ~/aios-iso/
# Output: ~/aios-iso/out/archlinux-*.iso  (rename to aios-*.iso)

# 8. Write to USB (replace sdX with your device!)
sudo dd if=~/aios-iso/out/aios-0.3.0.iso of=/dev/sdX bs=4M status=progress oflag=sync
```

### ISO size estimates
| Component | Size |
|-----------|------|
| Ubuntu base (debootstrap) | ~400 MB |
| Arch base (archiso) | ~800 MB |
| AIOS + Python deps | ~200 MB |
| NVIDIA drivers (optional) | ~500 MB |
| Docker (in ISO) | ~100 MB |
| **Total (no NVIDIA)** | **~700–1100 MB** |
| **Total (with NVIDIA)** | **~1200–1600 MB** |

---

## Uninstall

```bash
# Stop service
sudo systemctl stop aios-backend
sudo systemctl disable aios-backend
sudo rm /etc/systemd/system/aios-backend.service
sudo systemctl daemon-reload

# Remove files
sudo rm -rf /opt/aios
sudo rm /usr/local/bin/aios
sudo rm -rf /var/log/aios

# Optionally remove projects (careful!)
# rm -rf ~/aios-projects
```

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `aios: command not found` | Check `/usr/local/bin/aios` exists and is executable |
| Backend fails to start | `journalctl -u aios-backend -n 50` or `tail /var/log/aios/backend.log` |
| Port 7860 already in use | `AIOS_PORT=7861 aios start` or kill the process using the port |
| Docker: permission denied | Log out and back in (docker group change) |
| NVIDIA GPU not recognized | `nvidia-smi` works? If not, install drivers first |
| Python import errors | Re-run `./install.sh` or manually: `/opt/aios/venv/bin/pip install -r /opt/aios/backend/requirements.txt` |
