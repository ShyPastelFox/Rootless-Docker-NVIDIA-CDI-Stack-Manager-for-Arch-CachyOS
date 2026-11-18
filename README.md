<p align="center">
  <img src="https://img.shields.io/badge/Docker-Rootless-10b981?style=for-the-badge&logo=docker&logoColor=white" alt="Docker Rootless">
  <img src="https://img.shields.io/badge/NVIDIA-CDI-10b981?style=for-the-badge&logo=nvidia&logoColor=white" alt="NVIDIA CDI">
  <img src="https://img.shields.io/badge/version-2.5-fb7185?style=for-the-badge" alt="Version 2.5">
  <img src="https://img.shields.io/badge/shell-bash-fb7185?style=for-the-badge&logo=gnubash&logoColor=white" alt="Bash">
</p>

<h1 align="center">Docker Stack Manager</h1>

<p align="center">
  A terminal menu for managing Docker Compose stacks on <b>rootless Docker</b>,
  with automatic repair of NVIDIA CDI GPU configuration.
</p>

---

## 🖼️ Screenshots


| Main menu | Launching a stack |
|---|---|
| ![Main menu](<img width="1058" height="767" alt="image" src="https://github.com/user-attachments/assets/0dd5962d-a199-4798-88ed-eff0e62719c9" />
) | ![Launching a stack](<img width="1920" height="935" alt="image" src="https://github.com/user-attachments/assets/3f9d700a-c039-4d1d-94cc-f2889b543cb3" />
) |

| Stopping a stack | CDI repair |
|---|---|
| ![Stopping a stack](<img width="1920" height="954" alt="image" src="https://github.com/user-attachments/assets/f8d26ade-439d-41d1-bdd0-9b773a76dfb8" />
) | ![CDI repair](<img width="1919" height="1010" alt="image" src="https://github.com/user-attachments/assets/b55c835d-009e-4c90-b62a-dff61a0616ba" />
) |

---

## ✨ Features

- Start, stop and restart Docker Compose stacks from one menu
- Register stacks by name and path, and remove them from the list again
- List, remove, and clean up stopped or stuck containers
- View container logs, live or as a snapshot
- **Automatic NVIDIA CDI repair** before each launch, and a retry if a launch fails with a GPU mount error
- Keeps Docker Compose's live progress display while still reading errors
- Writes a log of every action

---

## ⚠️ Read before you use this

These points describe how the script behaves, including the parts that change files or restart services.

### It deletes files without asking

Before every launch, the script looks for NVIDIA CDI spec files in:

| Directory | Notes |
|---|---|
| `/etc/cdi` | Root-owned, removed with `sudo` |
| `/var/run/cdi` | Runtime directory, removed with `sudo` |
| `~/.config/cdi` | Your user directory, removed without `sudo` |

**Any nvidia.* file in these directories is deleted automatically, except /etc/cdi/nvidia.json. This includes spec files that are current, not just outdated ones, and it happens without a prompt.** Any container runtime that uses CDI, such as Docker or Podman, loses GPU access until a spec is regenerated. If you keep hand-written NVIDIA specs in these directories, they will be removed. 

Currently Working on a version that allows manual deletion to outdated configs.

### It restarts rootless Docker

When a repair is needed, or when option 10 runs, the script restarts `docker` with `systemctl --user restart docker`. **Running containers are stopped.** The script asks first when containers are running during option 10, but an automatic repair before a launch goes ahead without asking.

### When it needs `sudo`

Installing the regenerated spec, and deleting root-owned spec files, both use `sudo`. You will be asked for your password once per repair.

### It only supports NVIDIA

The GPU checks depend on `nvidia-smi` and `nvidia-ctk`. Other GPU vendors are not supported.

---

## 📋 Requirements

| Requirement | Why |
|---|---|
| **Rootless Docker** running as a **systemd user service** named `docker` | The script checks `systemctl --user is-active docker` and restarts it |
| **Docker Compose v2** (`docker compose`), or the legacy `docker-compose` | Used to start and stop stacks |
| **NVIDIA driver** with `nvidia-smi` | Reads the installed driver version |
| **nvidia-container-toolkit** (`nvidia-ctk`) | Generates the CDI spec. Without it, the repair step is skipped |
| **util-linux** (`script`) | Keeps Compose's live progress display. Without it, the display is plain text |
| **sudo** | Writes and removes CDI spec files |
| *(optional)* **lazydocker** | Opened from the menu with option 11 |

---

## 🚀 Installation

### 1. Set up rootless Docker

If rootless Docker is not running yet, follow the official guide:
https://docs.docker.com/engine/security/rootless/

Check that the user service is active:

```bash
systemctl --user is-active docker
```

It should print `active`. If it doesn't, start the service with `systemctl --user start docker`.

### 2. Install the NVIDIA container toolkit

Follow NVIDIA's instructions for your distribution. On Arch-based systems this is usually:

```bash
sudo pacman -S nvidia-container-toolkit
```

Check that the CDI tools work:

```bash
nvidia-smi
nvidia-ctk --version
```

## 3. Install the manager

Download `docker-manager.sh`, then install it into your user `bin` folder:

```bash
install -m 0700 docker-manager.sh ~/.local/bin/docker-manager
```

### File permissions

The `-m` value sets who can read, write, and run the script.

| Option | Owner | Group | Others | Use when |
|---|:---:|:---:|:---:|---|
| `0700` **(recommended)** | `rwx` | `---` | `---` | Only you use the machine |
| `0755` | `rwx` | `r-x` | `r-x` | Other users should be able to run the script |

With `0700`, no other account can see or run the script. With `0755`, other users can read and run it, but they still can't change it. Your registry, log, and any repair actions still run under your own account.

### 4. Run it

```bash
docker-manager
```

or if you are on KDE it will register as an application on your launcher.


The script must run from an interactive terminal. It will refuse to start when piped or run from a script.

### 5. Register your first stack

1. Choose **4** (Register stack)
2. Enter a name, for example `Ollama`
3. Enter the full path to your `docker-compose.yml`

The registry is saved to `~/.config/docker-registry.txt`.

---

## 🧭 Usage

| Option | Action |
|---|---|
| 1 | Launch a stack (`docker compose up -d`) |
| 2 | Stop a stack (`docker compose down`, volumes kept) |
| 3 | Restart a stack |
| 4 | Register a stack |
| 5 | Deregister a stack (containers are not touched) |
| 6 | List containers |
| 7 | Remove a container |
| 8 | Clean up stopped and stuck containers |
| 9 | View container logs |
| 10 | Regenerate the NVIDIA CDI spec and restart Docker |
| 11 | Open lazydocker |
| 12 | View the manager log |
| q | Quit |

### What happens on launch

1. The script checks the NVIDIA CDI config. If it is stale, duplicated, or points at missing files, it is repaired first.
2. The stack starts. Containers that were stuck in `created` are recreated after a repair.
3. If the launch fails with a GPU mount error, the spec is regenerated and the launch is retried once.

---

## 🗂️ Files the script uses

| Path | Purpose |
|---|---|
| `~/.config/docker-registry.txt` | Registered stacks |
| `~/.local/state/docker-manager.log` | Action log (falls back to `/tmp` if needed) |
| `/etc/cdi/nvidia.json` | The CDI spec the script writes |

---

## 🧪 Testing status

| Area | Status |
|---|---|
| Stale-spec detection and deletion | Tested with fake commands |
| Launch repair and container recreation | Tested with fake commands |
| Terminal progress display | Tested with fake commands and a pseudo-terminal |
| Missing-library refusal | Tested with fake commands |
| Real NVIDIA hardware | **Not verified** on this setup |
| Other driver versions | **Not verified** |
| Other Linux distributions | **Not verified** |

Treat this as tested on the author's setup only. Check it on a second machine before relying on it there.

---

## 🛠️ Troubleshooting

**"Rootless Docker is not active"**
Start the user service: `systemctl --user start docker`. Check the status with `systemctl --user status docker`.

**"'nvidia-ctk' not found"**
Install the NVIDIA container toolkit, then try again.

**Launch fails with `libEGL_nvidia` or `failed to fulfil mount request`**
Run option 10. If it refuses to install the spec, the NVIDIA driver libraries are incomplete. Reinstall the driver packages.

**"Could not delete" a spec file**
The file is probably root-owned and `sudo` was refused. Remove it by hand: `sudo rm /etc/cdi/<file>`.

**Containers stuck in `created`**
Run option 8, or let the next launch recreate them.

**No live progress display**
Install `util-linux` (it provides `script`).

---

## 📜 Licence

GNU General Public License V2.0
---

<p align="center">
  <img src="https://img.shields.io/badge/built%20for-rootless%20docker-10b981?style=flat-square" alt="built for rootless docker">
  <img src="https://img.shields.io/badge/made%20with-bash-fb7185?style=flat-square&logo=gnubash&logoColor=white" alt="made with bash">
</p>
