#!/usr/bin/env python3
"""
aios_cli/commands/service.py
─────────────────────────────
Implements:  aios start | stop | status | restart | logs

These are the system-level lifecycle commands that complement the Python
Typer-based CLI commands in aios.py.

This module is imported by aios.py and registered as extra commands so that
`aios start`, `aios stop`, etc. work identically whether invoked via:
  - the /usr/local/bin/aios bash wrapper (fastest path)
  - `python aios.py start` directly
"""
from __future__ import annotations

import os
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

import typer
from rich.console import Console
from rich.panel import Panel
from rich.table import Table
from rich import box

console = Console()

# ── Defaults (overridden by env vars set during install) ──────────────────────
AIOS_INSTALL_DIR = Path(os.environ.get("AIOS_INSTALL_DIR", "/opt/aios"))
AIOS_VENV_DIR    = Path(os.environ.get("AIOS_VENV",        "/opt/aios/venv"))
AIOS_PORT        = int(os.environ.get("AIOS_PORT",         "7860"))
AIOS_LOG_DIR     = Path(os.environ.get("AIOS_LOG",         "/var/log/aios"))
AIOS_PID_FILE    = Path("/tmp/aios-backend.pid")
AIOS_SERVICE     = "aios-backend"


# ── Helpers ───────────────────────────────────────────────────────────────────

def _systemd_available() -> bool:
    return shutil.which("systemctl") is not None

def _service_installed() -> bool:
    if not _systemd_available():
        return False
    r = subprocess.run(
        ["systemctl", "list-unit-files", f"{AIOS_SERVICE}.service"],
        capture_output=True, text=True
    )
    return AIOS_SERVICE in r.stdout

def _service_active() -> bool:
    r = subprocess.run(
        ["systemctl", "is-active", "--quiet", AIOS_SERVICE],
        capture_output=True
    )
    return r.returncode == 0

def _direct_pid() -> int | None:
    if AIOS_PID_FILE.exists():
        try:
            pid = int(AIOS_PID_FILE.read_text().strip())
            os.kill(pid, 0)   # check if alive
            return pid
        except (ValueError, ProcessLookupError, PermissionError):
            AIOS_PID_FILE.unlink(missing_ok=True)
    return None

def _port_listening() -> bool:
    """Check if the AIOS port is accepting connections."""
    import socket
    try:
        with socket.create_connection(("127.0.0.1", AIOS_PORT), timeout=1):
            return True
    except OSError:
        return False

def _open_browser() -> None:
    url = f"http://localhost:{AIOS_PORT}"
    if os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY"):
        xdg = shutil.which("xdg-open")
        if xdg:
            subprocess.Popen([xdg, url], stderr=subprocess.DEVNULL)
    elif shutil.which("open"):   # macOS (future)
        subprocess.Popen(["open", url], stderr=subprocess.DEVNULL)


# ── aios start ────────────────────────────────────────────────────────────────

def cmd_start(
    no_browser: bool = typer.Option(False, "--no-browser", help="Don't open browser after start"),
    port: int        = typer.Option(AIOS_PORT, "--port", "-p", help="Override port"),
) -> None:
    """Start the AIOS backend and dashboard."""

    console.print(
        Panel(
            "[bold cyan]AIOS[/bold cyan]  AI Developer OS  v0.3.0",
            border_style="cyan",
            padding=(0, 2),
        )
    )

    # ── Already running? ──────────────────────────────────────────────────────
    if _port_listening():
        console.print(f"[green]✓[/green] AIOS is already running at "
                      f"[bold cyan]http://localhost:{port}[/bold cyan]")
        return

    # ── Try systemd first ─────────────────────────────────────────────────────
    if _service_installed():
        console.print("[dim]  Starting via systemd...[/dim]")
        result = subprocess.run(["sudo", "systemctl", "start", AIOS_SERVICE])
        if result.returncode == 0:
            _wait_for_port(port)
            console.print(f"[green]✓[/green] AIOS backend started (systemd)")
            console.print(f"[dim]  Dashboard → [/dim][bold]http://localhost:{port}[/bold]")
            console.print(f"[dim]  Logs      → [/dim]journalctl -u {AIOS_SERVICE} -f")
            if not no_browser:
                _open_browser()
            return
        else:
            console.print("[yellow]⚠[/yellow] systemd start failed — falling back to direct launch")

    # ── Direct launch (fallback) ───────────────────────────────────────────────
    uvicorn_bin = AIOS_VENV_DIR / "bin" / "uvicorn"
    if not uvicorn_bin.exists():
        console.print(
            f"[red]✗[/red] uvicorn not found at {uvicorn_bin}\n"
            "  Run [bold]./install.sh[/bold] to set up the environment."
        )
        raise typer.Exit(1)

    backend_dir = AIOS_INSTALL_DIR / "backend"
    if not backend_dir.exists():
        console.print(f"[red]✗[/red] Backend not found at {backend_dir}")
        raise typer.Exit(1)

    AIOS_LOG_DIR.mkdir(parents=True, exist_ok=True)
    log_file = open(AIOS_LOG_DIR / "backend.log", "a")

    env = {
        **os.environ,
        "PYTHONPATH": str(backend_dir),
        "AIOS_PORT": str(port),
    }

    proc = subprocess.Popen(
        [
            str(uvicorn_bin), "app.main:app",
            "--host", "127.0.0.1",
            "--port", str(port),
            "--log-level", "info",
        ],
        cwd=str(backend_dir),
        env=env,
        stdout=log_file,
        stderr=log_file,
        start_new_session=True,   # detach from terminal
    )

    AIOS_PID_FILE.write_text(str(proc.pid))

    console.print(f"[dim]  Waiting for backend on port {port}...[/dim]")
    if _wait_for_port(port, timeout=15):
        console.print(f"[green]✓[/green] AIOS running  (PID {proc.pid})")
        console.print(f"[dim]  Dashboard → [/dim][bold]http://localhost:{port}[/bold]")
        console.print(f"[dim]  Logs      → [/dim]{AIOS_LOG_DIR}/backend.log")
        console.print(f"[dim]  Stop      → [/dim]aios stop")
        if not no_browser:
            _open_browser()
    else:
        console.print(
            f"[red]✗[/red] Backend did not respond within 15s.\n"
            f"  Check logs: tail -50 {AIOS_LOG_DIR}/backend.log"
        )
        proc.terminate()
        AIOS_PID_FILE.unlink(missing_ok=True)
        raise typer.Exit(1)


def _wait_for_port(port: int, timeout: int = 20) -> bool:
    import socket
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=1):
                return True
        except OSError:
            time.sleep(0.4)
    return False


# ── aios stop ─────────────────────────────────────────────────────────────────

def cmd_stop() -> None:
    """Stop the AIOS backend."""
    stopped = False

    if _service_installed() and _service_active():
        result = subprocess.run(["sudo", "systemctl", "stop", AIOS_SERVICE])
        if result.returncode == 0:
            console.print(f"[green]✓[/green] AIOS backend stopped (systemd)")
            stopped = True

    pid = _direct_pid()
    if pid:
        try:
            os.kill(pid, signal.SIGTERM)
            # Wait up to 5s for graceful shutdown
            for _ in range(10):
                try:
                    os.kill(pid, 0)
                    time.sleep(0.5)
                except ProcessLookupError:
                    break
            else:
                os.kill(pid, signal.SIGKILL)
            AIOS_PID_FILE.unlink(missing_ok=True)
            console.print(f"[green]✓[/green] AIOS backend stopped (PID {pid})")
            stopped = True
        except ProcessLookupError:
            AIOS_PID_FILE.unlink(missing_ok=True)

    if not stopped:
        console.print("[yellow]⚠[/yellow] AIOS does not appear to be running")


# ── aios restart ──────────────────────────────────────────────────────────────

def cmd_restart() -> None:
    """Restart the AIOS backend."""
    cmd_stop()
    time.sleep(1)
    cmd_start()


# ── aios status ───────────────────────────────────────────────────────────────

def cmd_status() -> None:
    """Show AIOS system status."""

    t = Table(box=box.ROUNDED, border_style="dim", header_style="bold cyan",
              show_header=False, padding=(0, 2))
    t.add_column("Component", style="dim", min_width=16)
    t.add_column("Status",    min_width=40)

    # Backend
    if _service_active():
        t.add_row("Backend", "[green]● running[/green]  [dim](systemd)[/dim]")
    elif (pid := _direct_pid()):
        t.add_row("Backend", f"[green]● running[/green]  [dim](direct PID {pid})[/dim]")
    else:
        t.add_row("Backend", "[red]○ stopped[/red]")

    # Dashboard
    if _port_listening():
        t.add_row("Dashboard", f"[green]● [bold]http://localhost:{AIOS_PORT}[/bold][/green]")
    else:
        t.add_row("Dashboard", "[dim]not reachable[/dim]")

    # Docker
    if shutil.which("docker"):
        r = subprocess.run(
            ["docker", "ps", "--filter", "name=aios-", "--format", "{{.Names}}"],
            capture_output=True, text=True
        )
        if r.returncode == 0:
            containers = [c for c in r.stdout.splitlines() if c]
            if containers:
                t.add_row("Docker", f"[green]● {len(containers)} container(s) running[/green]  "
                                    f"[dim]{', '.join(containers)}[/dim]")
            else:
                t.add_row("Docker", "[dim]running (0 aios containers)[/dim]")
        else:
            t.add_row("Docker", "[yellow]daemon not running[/yellow]")
    else:
        t.add_row("Docker", "[dim]not installed[/dim]")

    # GPU
    if shutil.which("nvidia-smi"):
        r = subprocess.run(
            ["nvidia-smi", "--query-gpu=name,utilization.gpu,memory.used,memory.total",
             "--format=csv,noheader,nounits"],
            capture_output=True, text=True
        )
        if r.returncode == 0 and r.stdout.strip():
            parts = [p.strip() for p in r.stdout.strip().split(",")]
            name = parts[0] if parts else "GPU"
            util = parts[1] if len(parts) > 1 else "?"
            mem_u = parts[2] if len(parts) > 2 else "?"
            mem_t = parts[3] if len(parts) > 3 else "?"
            t.add_row("GPU", f"[green]● {name}[/green]  [dim]{util}% GPU  {mem_u}/{mem_t} MB VRAM[/dim]")
        else:
            t.add_row("GPU", "[yellow]nvidia-smi error[/yellow]")
    else:
        t.add_row("GPU", "[dim]cpu-only[/dim]")

    # Install path
    t.add_row("Install", f"[dim]{AIOS_INSTALL_DIR}[/dim]")

    console.print("")
    console.print(Panel(t, title="[bold cyan]AIOS Status[/bold cyan]", border_style="cyan"))
    console.print("")


# ── aios logs ─────────────────────────────────────────────────────────────────

def cmd_logs(
    lines: int  = typer.Option(50,    "--lines", "-n", help="Last N lines to show"),
    follow: bool = typer.Option(True, "--follow/--no-follow", "-f", help="Follow log output"),
) -> None:
    """Stream AIOS backend logs."""
    if _service_installed():
        cmd = ["journalctl", "-u", AIOS_SERVICE, f"-n{lines}"]
        if follow:
            cmd.append("-f")
        os.execvp("journalctl", cmd)

    log_file = AIOS_LOG_DIR / "backend.log"
    if log_file.exists():
        if follow:
            os.execvp("tail", ["tail", f"-n{lines}", "-f", str(log_file)])
        else:
            subprocess.run(["tail", f"-n{lines}", str(log_file)])
    else:
        console.print("[yellow]⚠[/yellow] No log file found. Start AIOS first: [bold]aios start[/bold]")
