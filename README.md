# commander-installer

Audited bootstrap for the [Commander](https://runcommander.com) self-hosted worker: downloads the current release from `runcommander.com/releases`, verifies its sha256, checks the archive layout, then hands the verified tarball to the worker's own installer. It pins nothing and installs nothing by itself.

> **Audit before running as root.** Two scripts run on your box: this one (needs no root until the last step) and the worker's `install.sh` that it downloads. Use `--verify-only` to fetch both, read them, and only then run the install.

## Install

```sh
curl -fsSLO https://raw.githubusercontent.com/dekimuhq/commander-installer/main/install.sh
bash install.sh --verify-only      # no root: downloads + verifies into ./commander-release
less commander-release/install.sh  # read what will run as root
sudo bash install.sh --workdir commander-release
```

Do not pipe the script into `sh`: the worker's setup wizard reads your provider keys and license key from the terminal, and a pipe is not a terminal (the bootstrap refuses to continue without one).

## What this script does

1. Downloads `commander-worker.tar.gz`, `commander-worker.tar.gz.sha256` and `install.sh` from `https://runcommander.com/releases/` (override with `--release-base URL`).
2. Verifies the tarball against the `.sha256`. A missing or mismatching checksum stops the install — there is no fallback.
3. Checks the archive is flat (`./server.mjs`, `./commander-worker.service`, optionally `./commander-license.pub`): no nested dirs, no absolute paths, no `..`.
4. Prints the sha256 of the downloaded `install.sh` so you can compare it across downloads.
5. `--verify-only` exits here, files kept. Otherwise it requires root and a terminal, then runs `install.sh <verified tarball>`.

Nothing is written outside the work dir (a temp dir deleted on exit, or the `--workdir` you pass).

The checksum comes from the same origin as the tarball, so it proves the download is the file that was published (not truncated, not a stale cache) — it is not a signature and does not prove who published it. The `install.sh` has no published hash; it travels over HTTPS from the same origin.

## What runs as root — the worker's `install.sh`

Everything below happens inside the downloaded `install.sh`, not in this script. On Debian/Ubuntu with Node.js >= 22.13 already installed, it:

1. Checks the Node.js version and exits if it is too old (it does not install Node).
2. Installs the `claude` CLI globally with `npm install -g @anthropic-ai/claude-code` **if it is not already on `PATH`** — the only package install, and the only step that reaches npm.
3. Creates a `commander` system user (`/usr/sbin/nologin`) and `/opt/commander-worker`, `/var/lib/commander-worker` (0700, owned by `commander`), `/etc/commander-worker`.
4. Extracts the tarball into `/opt/commander-worker` (root-owned).
5. First run only: an interactive wizard asks for your provider keys and license key, generates `WORKER_SECRET` and `APPROVALS_SECRET`, and writes `/etc/commander-worker/env` (0600). Re-runs keep the existing file.
6. Installs `/etc/systemd/system/commander-worker.service` from the tarball with `ExecStart=` pinned to your `node` binary, then `daemon-reload`, `enable`, `start` (or `restart` on update).
7. Checks `http://127.0.0.1:7891/healthz` and exits non-zero if the worker did not come up.

The worker binds `127.0.0.1:7891` only; exposing it over HTTPS and pairing it with the dashboard are your next steps, documented on the dashboard's install page.

## Requirements

- Debian/Ubuntu with systemd, root access, a terminal.
- `curl`, `tar`, `sha256sum` (coreutils).
- Node.js >= 22.13 on `PATH` before you run the install step.

## Status

Commander is in a private beta. The release at `runcommander.com/releases` is the one the dashboard's install page points at; this bootstrap tracks it by URL, not by a pinned version, and fails closed until the `.sha256` side file is published next to it.

## License

[MIT](./LICENSE)
