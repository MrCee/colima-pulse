# containers/

This folder is a **local staging area** for “container installers”.

A **container installer** is simply a file that contains one (or more) `docker run ...` commands that the main script can detect and execute.  
Because real `docker run` commands often include **tokens, API keys, auth headers, private URLs, or other secrets**, we treat this folder as **“local by default”**.

---

## How the main script decides what to run

- The main script does **not** run “everything in this folder”.
- It scans files using its **discovery rules**.
- A file is only considered runnable if it contains a detectable `docker run ...` command (per the script’s detection logic).
- File extensions are **not** the point — a file can be named anything.  
  What matters is whether the file’s content matches the script’s discovery rules.

> `containers/README.md` is **documentation only** and is never executed.

---

## What is committed to the repo (public / safe)

These files are **safe to publish on GitHub** and are intentionally committed:

- `containers/README.md`  
  Documentation explaining how the folder works.

- `containers/example-*.sh` and `containers/template-*.sh`  
  **Sanitized example installers** (placeholders only, no secrets).  
  These exist so other people can copy them and create their own real installers locally.

**Rule of thumb:**  
If it’s safe to show the world, it can be an `example-*` or `template-*`.

---

## What stays local (NOT committed)

Everything else under `containers/` is assumed to be a **real installer** and may contain secrets, so it is **ignored by git** by default.

Examples of local-only files you might create:

- `containers/twingate-prod.sh`
- `containers/overseerr.sh`
- `containers/my-private-stack.txt`

These should **never** be committed unless you first sanitize them and convert them into an `example-*` file.

---

## Recommended workflow

1. Create real installers locally in `containers/` (these stay private and are ignored by git).
2. If you want to share an installer pattern publicly:
   - copy it to `containers/example-<name>.sh`
   - remove/replace secrets with placeholders
3. Run installs via the main script, which will scan the folder and execute only files that match its discovery rules (i.e., contain detectable `docker run` commands).

---

