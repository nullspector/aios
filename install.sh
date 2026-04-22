#!/usr/bin/env bash
# =============================================================================
#  AIOS — AI Developer Operating System  |  Installer v0.3.0
#  Supports: Ubuntu 20.04/22.04/24.04 LTS  |  Arch Linux
#
#  Usage:
#    curl -fsSL https://raw.githubusercontent.com/nullspector/aios/main/install.sh | bash
#    OR:
#    git clone https://github.com/nullspector/aios && cd aios && ./install.sh
#
#  Options (env vars):
#    AIOS_PORT=7860          Dashboard port (default: 7860)
#    AIOS_NO_GPU=1           Skip GPU/CUDA detection
#    AIOS_NO_DOCKER=1        Skip Docker install
#    AIOS_INSTALL_DIR=...    Override install location (default: /opt/aios)
#    AIOS_REPO_DIR=...       Path to already-cloned repo (default: auto-detect)
# =============================================================================

set -euo pipefail

# ── Colour helpers ─────────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'

err()  { echo -e "${RED}[✗] $*${RESET}" >&2; }
warn() { echo -e "${YELLOW}[⚠] $*${RESET}"; }
ok()   { echo -e "${GREEN}[✓] $*${RESET}"; }
info() { echo -e "${CYAN}[→] $*${RESET}"; }
dim()  { echo -e "${DIM}    $*${RESET}"; }
header() {
    echo ""
    echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "${BOLD}${CYAN}  $*${RESET}"
    echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
}

# ── Banner ─────────────────────────────────────────────────────────────────────
echo -e "${BOLD}${CYAN}"
cat <<'EOF'
   █████╗ ██╗ ██████╗ ███████╗
  ██╔══██╗██║██╔═══██╗██╔════╝
  ███████║██║██║   ██║███████╗
  ██╔══██║██║██║   ██║╚════██║
  ██║  ██║██║╚██████╔╝███████║
  ╚═╝  ╚═╝╚═╝ ╚═════╝ ╚══════╝
EOF
echo -e "${RESET}${DIM}  AI Developer Operating System  —  Installer v0.3.0${RESET}"
echo ""

# ── Config ─────────────────────────────────────────────────────────────────────
AIOS_PORT="${AIOS_PORT:-7860}"
AIOS_INSTALL_DIR="${AIOS_INSTALL_DIR:-/opt/aios}"
AIOS_VENV_DIR="${AIOS_INSTALL_DIR}/venv"
AIOS_BIN="/usr/local/bin/aios"
AIOS_SERVICE_FILE="/etc/systemd/system/aios-backend.service"
AIOS_LOG_DIR="/var/log/aios"
AIOS_PROJECTS_DIR="${HOME}/aios-projects"

# Detect repo root: if install.sh is inside the repo, use that path
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/backend/app/main.py" ]]; then
    AIOS_REPO_DIR="${AIOS_REPO_DIR:-${SCRIPT_DIR}}"
else
    AIOS_REPO_DIR="${AIOS_REPO_DIR:-${AIOS_INSTALL_DIR}/repo}"
fi

SKIP_GPU="${AIOS_NO_GPU:-0}"
SKIP_DOCKER="${AIOS_NO_DOCKER:-0}"
HAS_NVIDIA=0
HAS_SYSTEMD=0

# ── Preflight ──────────────────────────────────────────────────────────────────
header "PHASE 0 — Pre-flight checks"

# Must run as root or with sudo available
if [[ "${EUID}" -ne 0 ]]; then
    if ! command -v sudo &>/dev/null; then
        err "This installer must be run as root (sudo not found)."
        exit 1
    fi
    SUDO="sudo"
else
    SUDO=""
fi

# Detect OS
if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_LIKE="${ID_LIKE:-}"
else
    err "Cannot detect OS (/etc/os-release missing). Only Ubuntu and Arch are supported."
    exit 1
fi

case "${OS_ID}" in
    ubuntu|debian|linuxmint|pop)   DISTRO="ubuntu" ;;
    arch|manjaro|endeavouros)      DISTRO="arch"   ;;
    *)
        if [[ "${OS_LIKE}" == *"debian"* || "${OS_LIKE}" == *"ubuntu"* ]]; then
            DISTRO="ubuntu"
        elif [[ "${OS_LIKE}" == *"arch"* ]]; then
            DISTRO="arch"
        else
            err "Unsupported OS: ${OS_ID}. Supported: Ubuntu, Debian, Arch Linux."
            exit 1
        fi
        ;;
esac

ok "Detected OS: ${OS_ID} (treating as ${DISTRO})"

# Detect systemd
if command -v systemctl &>/dev/null && systemctl is-system-running &>/dev/null 2>&1; then
    HAS_SYSTEMD=1
    ok "systemd detected"
else
    warn "systemd not detected — service auto-start will be skipped"
fi

# Detect NVIDIA GPU
if [[ "${SKIP_GPU}" != "1" ]]; then
    if command -v nvidia-smi &>/dev/null; then
        HAS_NVIDIA=1
        GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || echo "NVIDIA GPU")
        ok "NVIDIA GPU detected: ${GPU_NAME}"
    elif lspci 2>/dev/null | grep -qi "nvidia\|geforce\|quadro\|tesla"; then
        HAS_NVIDIA=1
        warn "NVIDIA GPU detected in PCI but nvidia-smi not installed yet (will install drivers)"
    else
        info "No NVIDIA GPU detected — CPU-only mode"
    fi
fi

echo ""
echo -e "  ${DIM}Install dir:  ${AIOS_INSTALL_DIR}${RESET}"
echo -e "  ${DIM}Repo source:  ${AIOS_REPO_DIR}${RESET}"
echo -e "  ${DIM}Dashboard:    http://localhost:${AIOS_PORT}${RESET}"
echo -e "  ${DIM}Projects dir: ${AIOS_PROJECTS_DIR}${RESET}"
echo ""

# ── Helper: package install ────────────────────────────────────────────────────
pkg_install() {
    case "${DISTRO}" in
        ubuntu) ${SUDO} apt-get install -y --no-install-recommends "$@" ;;
        arch)   ${SUDO} pacman -S --noconfirm --needed "$@" ;;
    esac
}

pkg_update() {
    case "${DISTRO}" in
        ubuntu) ${SUDO} apt-get update -qq ;;
        arch)   ${SUDO} pacman -Sy --noconfirm ;;
    esac
}

# ── PHASE 1 — Core dependencies ───────────────────────────────────────────────
header "PHASE 1 — Installing system dependencies"

info "Refreshing package index..."
pkg_update

# Core tools
info "Installing core tools (git, curl, wget, build-essential)..."
case "${DISTRO}" in
    ubuntu)
        pkg_install git curl wget ca-certificates gnupg lsb-release \
                    build-essential software-properties-common
        ;;
    arch)
        pkg_install git curl wget ca-certificates base-devel
        ;;
esac
ok "Core tools installed"

# ── Python 3.10+ ──────────────────────────────────────────────────────────────
info "Checking Python version..."

PYTHON_OK=0
for pybin in python3.12 python3.11 python3.10 python3; do
    if command -v "${pybin}" &>/dev/null; then
        PY_VER=$("${pybin}" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
        PY_MAJOR=$(echo "${PY_VER}" | cut -d. -f1)
        PY_MINOR=$(echo "${PY_VER}" | cut -d. -f2)
        if [[ "${PY_MAJOR}" -ge 3 && "${PY_MINOR}" -ge 10 ]]; then
            PYTHON_BIN="${pybin}"
            PYTHON_OK=1
            ok "Python ${PY_VER} found at $(command -v ${pybin})"
            break
        fi
    fi
done

if [[ "${PYTHON_OK}" -eq 0 ]]; then
    info "Python 3.10+ not found — installing..."
    case "${DISTRO}" in
        ubuntu)
            ${SUDO} add-apt-repository -y ppa:deadsnakes/ppa 2>/dev/null || true
            pkg_update
            pkg_install python3.11 python3.11-venv python3.11-dev python3-pip
            PYTHON_BIN="python3.11"
            ;;
        arch)
            pkg_install python python-pip
            PYTHON_BIN="python3"
            ;;
    esac
    ok "Python installed: $(${PYTHON_BIN} --version)"
fi

# Ensure pip and venv
if ! "${PYTHON_BIN}" -m pip --version &>/dev/null; then
    case "${DISTRO}" in
        ubuntu) pkg_install python3-pip ;;
        arch)   pkg_install python-pip ;;
    esac
fi

if ! "${PYTHON_BIN}" -m venv --help &>/dev/null; then
    case "${DISTRO}" in
        ubuntu)
            PY_VER_MAJOR_MINOR="${PYTHON_BIN##python}"  # e.g. "3.11"
            pkg_install "python${PY_VER_MAJOR_MINOR}-venv" || pkg_install python3-venv
            ;;
        arch) : ;; # included with python
    esac
fi

ok "pip and venv available"

# ── Docker ────────────────────────────────────────────────────────────────────
if [[ "${SKIP_DOCKER}" != "1" ]]; then
    if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
        ok "Docker already installed and running ($(docker --version | head -1))"
    else
        info "Installing Docker..."
        case "${DISTRO}" in
            ubuntu)
                # Official Docker repo
                ${SUDO} install -m 0755 -d /etc/apt/keyrings
                curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
                    | ${SUDO} gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null
                ${SUDO} chmod a+r /etc/apt/keyrings/docker.gpg
                echo \
                  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
                  https://download.docker.com/linux/ubuntu \
                  $(. /etc/os-release && echo "${VERSION_CODENAME:-$(lsb_release -cs)}") stable" \
                  | ${SUDO} tee /etc/apt/sources.list.d/docker.list > /dev/null
                pkg_update
                pkg_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
                ;;
            arch)
                pkg_install docker docker-compose
                ;;
        esac

        ${SUDO} systemctl enable docker --now 2>/dev/null || true

        # Add current user to docker group (no-sudo docker)
        if [[ -n "${SUDO_USER:-}" ]]; then
            ${SUDO} usermod -aG docker "${SUDO_USER}"
            warn "Added ${SUDO_USER} to 'docker' group. You must log out & back in for this to take effect."
        elif [[ "${EUID}" -ne 0 ]]; then
            ${SUDO} usermod -aG docker "${USER}"
            warn "Added ${USER} to 'docker' group. Log out and back in for group to apply."
        fi

        ok "Docker installed"
    fi

    # Docker Compose (standalone)
    if ! command -v docker-compose &>/dev/null && ! docker compose version &>/dev/null 2>&1; then
        info "Installing docker-compose..."
        COMPOSE_VERSION="v2.27.0"
        COMPOSE_ARCH=$(uname -m)
        ${SUDO} curl -fsSL \
            "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-linux-${COMPOSE_ARCH}" \
            -o /usr/local/bin/docker-compose
        ${SUDO} chmod +x /usr/local/bin/docker-compose
        ok "docker-compose installed"
    fi
fi

# ── PHASE 2 — GPU support ─────────────────────────────────────────────────────
header "PHASE 2 — GPU support"

if [[ "${SKIP_GPU}" == "1" ]]; then
    info "GPU detection skipped (AIOS_NO_GPU=1)"
elif [[ "${HAS_NVIDIA}" -eq 1 ]]; then
    # nvidia-container-toolkit (needed for --gpus in docker)
    if ! command -v nvidia-container-toolkit &>/dev/null && \
       ! dpkg -l nvidia-container-toolkit &>/dev/null 2>&1 && \
       ! pacman -Q nvidia-container-toolkit &>/dev/null 2>&1; then
        info "Installing nvidia-container-toolkit..."
        case "${DISTRO}" in
            ubuntu)
                curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
                    | ${SUDO} gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg 2>/dev/null
                curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
                    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
                    | ${SUDO} tee /etc/apt/sources.list.d/nvidia-container-toolkit.list > /dev/null
                pkg_update
                pkg_install nvidia-container-toolkit
                ;;
            arch)
                # AUR — check if yay/paru is available
                if command -v yay &>/dev/null; then
                    yay -S --noconfirm nvidia-container-toolkit
                elif command -v paru &>/dev/null; then
                    paru -S --noconfirm nvidia-container-toolkit
                else
                    warn "AUR helper (yay/paru) not found. Install nvidia-container-toolkit manually:"
                    warn "  https://github.com/NVIDIA/nvidia-container-toolkit"
                fi
                ;;
        esac

        # Configure docker to use nvidia runtime
        if command -v docker &>/dev/null; then
            ${SUDO} nvidia-ctk runtime configure --runtime=docker 2>/dev/null || true
            ${SUDO} systemctl restart docker 2>/dev/null || true
            ok "NVIDIA container toolkit installed and Docker configured"
        fi
    else
        ok "nvidia-container-toolkit already installed"
    fi

    # Quick CUDA check (don't install full CUDA — too heavy for installer)
    if ! "${PYTHON_BIN}" -c "import torch; assert torch.cuda.is_available()" 2>/dev/null; then
        warn "PyTorch CUDA not yet configured."
        warn "Run: aios wizard  to auto-install the correct PyTorch+CUDA build for your GPU."
    else
        ok "PyTorch + CUDA is working"
    fi
else
    info "No NVIDIA GPU — running in CPU-only mode"
    info "Connect a remote GPU later with: aios remote add <name> user@host"
fi

# ── PHASE 3 — Install AIOS ────────────────────────────────────────────────────
header "PHASE 3 — Installing AIOS"

# Clone repo if not already present
if [[ ! -f "${AIOS_REPO_DIR}/backend/app/main.py" ]]; then
    AIOS_REMOTE="${AIOS_REMOTE:-https://github.com/nullspector/aios.git}"
    info "Cloning AIOS from ${AIOS_REMOTE}..."
    ${SUDO} mkdir -p "${AIOS_INSTALL_DIR}"
    ${SUDO} chown "${USER}:${USER}" "${AIOS_INSTALL_DIR}" 2>/dev/null || true
    git clone --depth 1 "${AIOS_REMOTE}" "${AIOS_REPO_DIR}"
    ok "Repository cloned to ${AIOS_REPO_DIR}"
else
    ok "Repo found at ${AIOS_REPO_DIR}"
fi

# Copy repo to install dir (if different paths)
if [[ "${AIOS_REPO_DIR}" != "${AIOS_INSTALL_DIR}" ]]; then
    info "Copying AIOS to ${AIOS_INSTALL_DIR}..."
    ${SUDO} mkdir -p "${AIOS_INSTALL_DIR}"
    ${SUDO} rsync -a --delete \
        --exclude='.git' \
        --exclude='__pycache__' \
        --exclude='*.pyc' \
        --exclude='.env' \
        "${AIOS_REPO_DIR}/" "${AIOS_INSTALL_DIR}/"
    ${SUDO} chown -R "${USER}:${USER}" "${AIOS_INSTALL_DIR}" 2>/dev/null || true
    ok "AIOS installed to ${AIOS_INSTALL_DIR}"
fi

# ── Python venv ───────────────────────────────────────────────────────────────
info "Setting up Python virtual environment at ${AIOS_VENV_DIR}..."
"${PYTHON_BIN}" -m venv "${AIOS_VENV_DIR}"

VENV_PIP="${AIOS_VENV_DIR}/bin/pip"
VENV_PYTHON="${AIOS_VENV_DIR}/bin/python"

# Upgrade pip first
"${VENV_PIP}" install --quiet --upgrade pip setuptools wheel

# Install backend dependencies
BACKEND_REQ="${AIOS_INSTALL_DIR}/backend/requirements.txt"
if [[ -f "${BACKEND_REQ}" ]]; then
    info "Installing backend Python dependencies..."
    "${VENV_PIP}" install --quiet -r "${BACKEND_REQ}"
    ok "Backend dependencies installed"
else
    warn "requirements.txt not found at ${BACKEND_REQ} — installing defaults..."
    "${VENV_PIP}" install --quiet "fastapi>=0.110.0" "uvicorn[standard]>=0.29.0" "psutil>=5.9.8"
fi

# Install CLI dependencies
info "Installing CLI dependencies..."
"${VENV_PIP}" install --quiet "typer>=0.12.0" "rich>=13.7.0"
ok "CLI dependencies installed"

# ── aios projects directory ────────────────────────────────────────────────────
mkdir -p "${AIOS_PROJECTS_DIR}"
ok "Projects directory: ${AIOS_PROJECTS_DIR}"

# ── Log directory ─────────────────────────────────────────────────────────────
${SUDO} mkdir -p "${AIOS_LOG_DIR}"
${SUDO} chown "${USER}:${USER}" "${AIOS_LOG_DIR}" 2>/dev/null || true

# ── PHASE 4 — CLI wrapper ─────────────────────────────────────────────────────
header "PHASE 4 — Installing CLI"

info "Writing global aios command to ${AIOS_BIN}..."

${SUDO} tee "${AIOS_BIN}" > /dev/null <<WRAPPER
#!/usr/bin/env bash
# AIOS CLI wrapper — auto-generated by install.sh
# Do not edit; re-run install.sh to regenerate

AIOS_INSTALL_DIR="${AIOS_INSTALL_DIR}"
AIOS_VENV="${AIOS_VENV_DIR}"
AIOS_PORT="${AIOS_PORT}"
AIOS_LOG="${AIOS_LOG_DIR}"

# ── aios start ────────────────────────────────────────────────────────────────
_start() {
    if systemctl is-active --quiet aios-backend 2>/dev/null; then
        echo -e "\033[0;32m[✓] AIOS backend is already running\033[0m"
        echo -e "\033[2m    Dashboard → http://localhost:\${AIOS_PORT}\033[0m"
        return 0
    fi

    if systemctl list-unit-files aios-backend.service &>/dev/null 2>&1; then
        echo -e "\033[0;36m[→] Starting AIOS backend via systemd...\033[0m"
        sudo systemctl start aios-backend
        sleep 1
        if systemctl is-active --quiet aios-backend; then
            echo -e "\033[0;32m[✓] AIOS is running\033[0m"
            echo -e "\033[2m    Dashboard → http://localhost:\${AIOS_PORT}\033[0m"
            echo -e "\033[2m    Logs      → journalctl -u aios-backend -f\033[0m"
            _open_browser
        else
            echo -e "\033[0;31m[✗] Failed to start. Check: journalctl -u aios-backend -n 50\033[0m"
            return 1
        fi
    else
        # Fallback: direct uvicorn
        echo -e "\033[0;36m[→] Starting AIOS backend directly...\033[0m"
        cd "\${AIOS_INSTALL_DIR}/backend"
        PYTHONPATH="\${AIOS_INSTALL_DIR}/backend" \\
            "\${AIOS_VENV}/bin/uvicorn" app.main:app \\
                --host 127.0.0.1 \\
                --port "\${AIOS_PORT}" \\
                --log-level warning &
        BACKEND_PID=\$!
        echo "\${BACKEND_PID}" > /tmp/aios.pid
        sleep 1
        if kill -0 "\${BACKEND_PID}" 2>/dev/null; then
            echo -e "\033[0;32m[✓] AIOS running (PID \${BACKEND_PID})\033[0m"
            echo -e "\033[2m    Dashboard → http://localhost:\${AIOS_PORT}\033[0m"
            echo -e "\033[2m    Stop with: aios stop\033[0m"
            _open_browser
        else
            echo -e "\033[0;31m[✗] Backend failed to start. Check \${AIOS_LOG}/backend.log\033[0m"
            return 1
        fi
    fi
}

_open_browser() {
    URL="http://localhost:\${AIOS_PORT}"
    if command -v xdg-open &>/dev/null && [[ -n "\${DISPLAY:-}\${WAYLAND_DISPLAY:-}" ]]; then
        xdg-open "\${URL}" &>/dev/null &
    elif command -v open &>/dev/null; then
        open "\${URL}" &>/dev/null &
    fi
}

# ── aios stop ─────────────────────────────────────────────────────────────────
_stop() {
    if systemctl list-unit-files aios-backend.service &>/dev/null 2>&1; then
        sudo systemctl stop aios-backend
        echo -e "\033[0;32m[✓] AIOS backend stopped\033[0m"
    elif [[ -f /tmp/aios.pid ]]; then
        PID=\$(cat /tmp/aios.pid)
        if kill "\${PID}" 2>/dev/null; then
            rm -f /tmp/aios.pid
            echo -e "\033[0;32m[✓] AIOS stopped (PID \${PID})\033[0m"
        else
            echo -e "\033[1;33m[⚠] No process at PID \${PID}\033[0m"
            rm -f /tmp/aios.pid
        fi
    else
        echo -e "\033[1;33m[⚠] AIOS does not appear to be running\033[0m"
    fi
}

# ── aios status ───────────────────────────────────────────────────────────────
_status() {
    echo ""
    echo -e "\033[1;36m  AIOS Status\033[0m"
    echo -e "\033[2m  ─────────────────────────────────────────\033[0m"

    # Backend service
    if systemctl is-active --quiet aios-backend 2>/dev/null; then
        echo -e "  Backend    \033[0;32m● running\033[0m  (systemd)"
    elif [[ -f /tmp/aios.pid ]] && kill -0 "\$(cat /tmp/aios.pid)" 2>/dev/null; then
        echo -e "  Backend    \033[0;32m● running\033[0m  (direct, PID \$(cat /tmp/aios.pid))"
    else
        echo -e "  Backend    \033[0;31m○ stopped\033[0m"
    fi

    # Port check
    if ss -ltn 2>/dev/null | grep -q ":\${AIOS_PORT}" || \
       netstat -ltn 2>/dev/null | grep -q ":\${AIOS_PORT}"; then
        echo -e "  Dashboard  \033[0;32m● http://localhost:\${AIOS_PORT}\033[0m"
    else
        echo -e "  Dashboard  \033[2mnot reachable\033[0m"
    fi

    # Docker
    if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
        AIOS_CONTAINERS=\$(docker ps --filter "name=aios-" --format "{{.Names}}" | wc -l)
        echo -e "  Docker     \033[0;32m● running\033[0m  (\${AIOS_CONTAINERS} aios containers)"
    else
        echo -e "  Docker     \033[2mnot running\033[0m"
    fi

    # GPU
    if command -v nvidia-smi &>/dev/null; then
        GPU=\$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
        echo -e "  GPU        \033[0;32m● \${GPU}\033[0m"
    else
        echo -e "  GPU        \033[2mcpu-only\033[0m"
    fi

    echo ""
}

# ── aios logs ─────────────────────────────────────────────────────────────────
_logs() {
    if systemctl list-unit-files aios-backend.service &>/dev/null 2>&1; then
        exec journalctl -u aios-backend -f --output=short-precise
    elif [[ -f "\${AIOS_LOG}/backend.log" ]]; then
        exec tail -f "\${AIOS_LOG}/backend.log"
    else
        echo "No logs found. Start AIOS first: aios start"
    fi
}

# ── aios restart ──────────────────────────────────────────────────────────────
_restart() {
    _stop
    sleep 1
    _start
}

# ── Dispatch ──────────────────────────────────────────────────────────────────
case "\${1:-}" in
    start)   _start  ;;
    stop)    _stop   ;;
    status)  _status ;;
    restart) _restart ;;
    logs)    _logs   ;;
    "")
        # No args → delegate to Python CLI
        exec "\${AIOS_VENV}/bin/python" "\${AIOS_INSTALL_DIR}/cli/aios.py" --help
        ;;
    *)
        # All other commands → Python CLI
        exec "\${AIOS_VENV}/bin/python" "\${AIOS_INSTALL_DIR}/cli/aios.py" "\$@"
        ;;
esac
WRAPPER

${SUDO} chmod +x "${AIOS_BIN}"
ok "aios command installed at ${AIOS_BIN}"

# ── PHASE 5 — systemd service ─────────────────────────────────────────────────
header "PHASE 5 — systemd service"

if [[ "${HAS_SYSTEMD}" -eq 1 ]]; then
    info "Writing systemd service file..."

    REAL_USER="${SUDO_USER:-${USER}}"
    REAL_HOME=$(getent passwd "${REAL_USER}" | cut -d: -f6)

    ${SUDO} tee "${AIOS_SERVICE_FILE}" > /dev/null <<SERVICE
[Unit]
Description=AIOS — AI Developer OS Backend
Documentation=https://github.com/nullspector/aios
After=network.target docker.service
Wants=docker.service

[Service]
Type=simple
User=${REAL_USER}
Group=${REAL_USER}
WorkingDirectory=${AIOS_INSTALL_DIR}/backend
Environment="PYTHONPATH=${AIOS_INSTALL_DIR}/backend"
Environment="AIOS_PORT=${AIOS_PORT}"
Environment="HOME=${REAL_HOME}"
ExecStart=${AIOS_VENV_DIR}/bin/uvicorn app.main:app \
    --host 127.0.0.1 \
    --port ${AIOS_PORT} \
    --log-level info \
    --access-log \
    --use-colors
ExecStop=/bin/kill -TERM \$MAINPID
Restart=on-failure
RestartSec=5
StartLimitIntervalSec=60
StartLimitBurst=3

# Logging
StandardOutput=append:${AIOS_LOG_DIR}/backend.log
StandardError=append:${AIOS_LOG_DIR}/backend.log

# Hardening (relaxed for local dev tool)
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ReadWritePaths=${AIOS_INSTALL_DIR} ${AIOS_LOG_DIR} ${REAL_HOME}

[Install]
WantedBy=multi-user.target
SERVICE

    ${SUDO} systemctl daemon-reload
    ${SUDO} systemctl enable aios-backend --now 2>/dev/null || ${SUDO} systemctl enable aios-backend
    ok "systemd service installed and enabled (aios-backend)"
    dim "Service will auto-start on next boot"
else
    warn "systemd not available — skipping service install"
    info "Use 'aios start' and 'aios stop' to manage the backend manually"
fi

# ── PHASE 6 — First run health check ──────────────────────────────────────────
header "PHASE 6 — Verifying installation"

# Check Python in venv
if "${VENV_PYTHON}" --version &>/dev/null; then
    ok "Python venv: $(${VENV_PYTHON} --version)"
fi

# Check FastAPI import
if "${VENV_PYTHON}" -c "import fastapi, uvicorn, psutil" 2>/dev/null; then
    ok "Backend dependencies: fastapi, uvicorn, psutil"
fi

# Check CLI
if "${AIOS_BIN}" version &>/dev/null 2>&1 || "${AIOS_VENV_DIR}/bin/python" "${AIOS_INSTALL_DIR}/cli/aios.py" --help &>/dev/null; then
    ok "AIOS CLI is working"
fi

# Check Docker
if [[ "${SKIP_DOCKER}" != "1" ]] && command -v docker &>/dev/null; then
    ok "Docker: $(docker --version | head -1)"
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${BOLD}${GREEN}  ✓  AIOS installed successfully!${RESET}"
echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
echo -e "  ${CYAN}Quick start:${RESET}"
echo -e "    ${BOLD}aios start${RESET}               Start the dashboard + backend"
echo -e "    ${BOLD}aios status${RESET}              Check what's running"
echo -e "    ${BOLD}aios stop${RESET}                Stop the backend"
echo -e "    ${BOLD}aios doctor${RESET}              Full environment health check"
echo -e "    ${BOLD}aios new my-model${RESET}        Create an AI project"
echo -e "    ${BOLD}aios gpu${RESET}                 GPU status"
echo ""
echo -e "  ${DIM}Dashboard:  http://localhost:${AIOS_PORT}${RESET}"
echo -e "  ${DIM}Install:    ${AIOS_INSTALL_DIR}${RESET}"
echo -e "  ${DIM}Projects:   ${AIOS_PROJECTS_DIR}${RESET}"
echo -e "  ${DIM}Logs:       ${AIOS_LOG_DIR}/backend.log${RESET}"
echo ""

if [[ "${HAS_SYSTEMD}" -eq 1 ]]; then
    echo -e "  ${DIM}Backend service starts automatically on boot.${RESET}"
    echo -e "  ${DIM}Manual control: systemctl {start|stop|status} aios-backend${RESET}"
fi
echo ""

# Optionally launch immediately
if [[ -t 0 ]]; then
    read -rp "  Launch AIOS now? [Y/n] " LAUNCH_NOW
    LAUNCH_NOW="${LAUNCH_NOW:-Y}"
    if [[ "${LAUNCH_NOW}" =~ ^[Yy]$ ]]; then
        "${AIOS_BIN}" start
    fi
fi
