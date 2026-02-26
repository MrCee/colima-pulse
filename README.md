# 🚀 Colima Pulse

![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)
![PRs: welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)
![Fixes: %2325](https://img.shields.io/badge/Fixes-%2325-6f42c1.svg)
![Last commit](https://img.shields.io/github/last-commit/MrCee/colima-pulse.svg)
![Platform: macOS](https://img.shields.io/badge/Platform-macOS-black.svg)
![Architecture: x86_64 | ARM64](https://img.shields.io/badge/Architecture-x86__64%20%7C%20ARM64-2f81f7.svg)

**🧱 Boot-level Docker infrastructure for macOS** — *pre-login • deterministic • supervised*  
*Colima • QEMU • LaunchDaemon • Terminal-first • Zero drift*

---

## 🧠 What is Colima Pulse?

Colima Pulse turns Colima into **boot-level Docker infrastructure** on macOS.

It does not “start Docker”.

It **provisions**, **verifies**, **supervises**, and **enforces** Docker — **before login, every time**.

If you need Docker on macOS to behave like a server (reliably, after reboot, without a GUI), this is for you.

---

## ✅ What you get (the practical benefits)

- 🟢 **Pre-login containers on macOS** without Docker Desktop  
  A **system LaunchDaemon** brings Colima up after boot (after disk unlock), not after a user session starts.

- 🧰 **Launchd-correct supervision** (no PID mismatch)  
  Colima runs as the supervised process (`exec ... --foreground`), not as a child of a wrapper shell.

- 🧪 **Deterministic readiness gating**  
  Socket presence ≠ Docker ready. Colima Pulse gates on **docker.sock + Docker API + stability threshold** before doing anything operational.

- 🧼 **Anti-drift controls (enforced, not suggested)**  
  Prevents split-brain state (`~/.colima` vs XDG) and can remove conflicting Colima launchd services that cause dual-VM behaviour.

- ♻️ **Idempotent, auditable container install pattern**  
  `./containers/` is treated as **operational intent**: explicit scripts, sequential execution, clean reinstall behaviour.

- 🧭 **Works on Intel and Apple Silicon**  
  Auto-detects architecture and uses the correct Homebrew prefix (`/usr/local` vs `/opt/homebrew`).

---

## 👥 Who this is for

- 🍺 **Homebrew admins** who want Docker as an always-on capability, not a desktop workflow  
- 🏠 **Homelab operators** running reverse proxies, VPN connectors, automations, and self-hosted services  
- 🔧 Developers who want **repeatability and recovery**, not “it worked until reboot”  
- 🧱 Anyone treating macOS like a small server that must boot cleanly and run headless

---

## ⚡ Quickstart

```bash
cp .env.example .env
# edit HOMEBREW_USER + resources (and optionally LABEL)
zsh ./colima-pulse.sh
```

Colima Pulse provisions Colima, installs a LaunchDaemon, verifies Docker is actually ready, then runs your container installers.

---

# 🔥 Philosophy

> Reset with intent.  
> Rebuild with certainty.  
> Verify before trust.

**Correctness by construction.**

No drift.  
No hidden state.  
No silent fallback.  
No GUI coupling.  
No session dependency.

**Infrastructure must boot. Not wait.**

---

# 🏗 Architecture overview

Colima Pulse enforces a strict boot model:

```text
macOS boot
   ↓
System LaunchDaemon (pre-login)
   ↓
su - USER  (login-style environment)
   ↓
exec colima start --foreground  (supervised PID)
   ↓
QEMU VM boot
   ↓
Docker runtime init
   ↓
docker.sock exposed
   ↓
Docker API verified + stabilised
   ↓
Container installers executed (./containers)
```

---

## 🧠 Why LaunchDaemon + `su -` + `exec`?

A LaunchDaemon runs in the **system domain** (exactly what we want for pre-login infrastructure), but it does **not** create a normal login environment.

Colima/Lima expect correct user context:

- 🏠 HOME + ownership
- 🧭 login-style environment
- 🧩 predictable paths
- 🧼 no XDG drift

So the LaunchDaemon runs Colima like this:

```sh
/usr/bin/su - USER -c "unset XDG_CONFIG_HOME; export HOME=...; exec colima start --foreground"
```

✅ `su - USER` → login-style environment for the correct user  
✅ `unset XDG_CONFIG_HOME` → prevents config/state drift into XDG locations  
✅ `export HOME=...` → ensures state lives where expected  
✅ `exec ... --foreground` → Colima becomes the supervised PID (no shell babysitting)

**Result:** Docker-capable infrastructure can be **up at boot**, not after you log in.

---

# ⚠️ Critical decision: QEMU vs VZ (Apple Silicon)

Colima supports two VM backends on Apple Silicon:

- `qemu`
- `vz` (Apple Virtualization.framework)

VZ is fast and deeply integrated — great for **interactive development**.

Colima Pulse targets a different problem: **pre-login reliability under system supervision**.

✅ **We’re optimising for infrastructure that boots cleanly and recovers predictably under `launchd`.**

---

## 🔒 Why Colima Pulse enforces QEMU

For boot-level supervision you want:

- 🧱 stable behaviour under `/Library/LaunchDaemons`
- 🔁 predictable lifecycle semantics under `launchd`
- 🚫 no dependency on a GUI/session bootstrap
- 🧪 repeatable cold-boot behaviour

QEMU consistently meets these constraints on macOS because it runs in userspace and behaves predictably under system supervision.

VZ can be excellent on a logged-in desktop, but for boot-level infrastructure it can introduce avoidable lifecycle ambiguity. Colima Pulse treats that ambiguity as a failure mode.

So:

- ✅ **QEMU is mandatory**
- ❌ **VZ is explicitly rejected**
- 🧨 If VZ is detected, Colima Pulse fails loudly

```bash
COLIMA_VM_TYPE=qemu
```

---

## 🔐 FileVault note

FileVault encrypts the disk at rest.

Until a user unlocks the disk at boot, user home directories are unavailable — this affects *everything*. After unlock, Colima Pulse can run pre-login as designed.

The distinction here is not encryption; it’s **launchd/session determinism**.

---

# ⚙️ What the script does

Run:

```bash
zsh ./colima-pulse.sh
```

Colima Pulse performs these phases:

---

## 🔥 1) Guarded reset (optional)

If:

```bash
FULL_RESET=true
```

It performs a guarded “nuclear reset”:

- 🛑 stops Colima
- 🧹 deletes the profile
- 🧨 removes state directories (both potential locations to prevent dual-state drift)
- 🧯 removes the LaunchDaemon
- 🧱 rebuilds from zero

No incremental patching.  
No drift accumulation.

---

## 🧱 2) Deterministic provisioning

- 🧰 provisions a fresh VM (**QEMU only**)
- 🧪 verifies VM backend (fails if VZ appears)
- ✅ brings up Docker socket + API cleanly

---

## 🖥 3) Supervised system LaunchDaemon

Installs:

```text
/Library/LaunchDaemons/<LABEL>.plist
```

Then bootstraps + kickstarts it.

The daemon becomes the **authoritative owner** of the Colima lifecycle.

---

## ⏳ 4) Deterministic readiness gates

The script waits for:

- 🔌 docker.sock presence
- 🧠 Docker API responsiveness
- 🧱 stability threshold (multiple consecutive successful checks)

No silent hangs.  
Hard timeouts.  
Fail-fast.

---

## ▶️ 5) Container installers

Once Docker is stable, the script runs installer files from:

```text
./containers/
```

---

# 📦 About `containers/`

The `containers/` directory is intentionally **simple and explicit**.

Each file is an executable script containing a `docker run ...` command. Colima Pulse treats this directory as **operational intent**:

- 🧾 scripts run **sequentially**
- ♻️ existing containers are removed first (idempotent reinstall)
- 📺 output is streamed live
- 🧨 failures stop the run (fail-fast)

This design is deliberate: it’s easy to audit, easy to version, and easy to keep secrets out of Git.

---

## 🤝 Why not Docker Compose?

Compose is great — but it introduces orchestration semantics and lifecycle complexity.

Colima Pulse keeps responsibilities separated:

- 🧱 **LaunchDaemon** supervises the platform (Colima)
- 📦 `containers/` declares what you want installed
- 👀 you retain complete visibility into exactly what runs

If you want Compose, you can still run it *inside* this model — but Colima Pulse itself stays lean and deterministic.

---

## ✅ What belongs in `containers/`?

Common examples:

- 🌐 reverse proxy (Caddy / Traefik / Nginx)
- 🔐 VPN connectors / sidecars
- 🤖 automations / schedulers
- 🏠 self-hosted services you want up at boot

**Keep secrets out of the repo.** Prefer environment variables or local `.env` values.

---

# 🔐 Configuration (`.env`)

Copy the example:

```bash
cp .env.example .env
```

Edit at minimum:

- 👤 `HOMEBREW_USER`
- 🧠 `COLIMA_CPUS`, `COLIMA_MEMORY`, `COLIMA_DISK`
- 🏷 `LABEL` (optional, but recommended to keep repo-canonical)

---

# 📍 What changes on your system?

Colima Pulse installs/uses:

- 🧾 **LaunchDaemon plist:** `/Library/LaunchDaemons/<LABEL>.plist`
- 🪵 **Log file:** `/var/log/colima.log`
- 🧊 **Colima state (forced):** `~/.colima/`

It also enforces a deterministic lifecycle:

- the daemon supervises Colima pre-login
- Docker readiness is verified before installers run
- optional “nuclear reset” wipes state and rebuilds cleanly

---

# 🔎 Observability

Log file:

```text
/var/log/colima.log
```

Useful checks:

```bash
sudo launchctl print system/<LABEL>
colima status --verbose
docker version
docker ps
```

---

# ❌ What this is not

Colima Pulse is not:

- Docker Desktop
- Kubernetes
- a GUI tool
- a state-preserving patch layer
- a general-purpose VM manager

It is intentionally opinionated.

It optimises for determinism.

---

# 🛡 Operational guarantees

Colima Pulse enforces:

- 🔒 QEMU only (no VZ drift)
- 🧱 system LaunchDaemon supervision (pre-login)
- 🎯 supervised PID lifecycle (`exec ... --foreground`)
- ✅ deterministic readiness gating (no “maybe ready”)
- ♻️ rebuild-over-patching when correctness matters

---

# 📌 Status

- ✅ Architecture stable
- ✅ LaunchDaemon model verified
- ✅ Deterministic cold boot proven
- ✅ QEMU enforced
- ✅ Production-usable

---

# 🧨 Final word

Colima Pulse does not patch problems.

It removes ambiguity.

It enforces correctness.

It boots infrastructure, not convenience.

---

**Colima Pulse**  
*Reset with intent. Rebuild with confidence.*
