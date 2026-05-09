# commander-installer

Single-shot installer for [`commander-worker`](https://github.com/dekimuhq/commander-worker) on Ubuntu 24.04 LTS.

> **Audit before piping to sh.** This is a public shell script that runs as root on your box. Read every line at [`install.sh`](./install.sh) before running it.

## Install

On a fresh Ubuntu 24.04 LTS host:

```sh
curl -fsSL https://raw.githubusercontent.com/dekimuhq/commander-installer/main/install.sh | sudo sh
```

The script:

1. Verifies the host is Ubuntu 24.04.
2. Installs Node.js 22 (NodeSource).
3. Creates a dedicated `commander` system user (`/usr/sbin/nologin`).
4. Fetches a pinned `commander-worker` tarball from a public [Vercel Blob](https://vercel.com/docs/storage/vercel-blob) mirror and verifies its sha256.
5. Extracts it to `/home/commander/worker`.
6. Drops a `/etc/commander-worker/env` skeleton with placeholder values (no secrets are baked in).
7. Installs a systemd unit `commander-worker.service`. **Does not start it.**

It is idempotent: running it twice in a row is a no-op.

## After install

1. Edit `/etc/commander-worker/env` and fill the `__FILL__` placeholders.
   - Generate `WORKER_SECRET` with `openssl rand -base64 32`.
   - Paste your `COMMANDER_LICENSE_PUBLIC_KEY` (PEM) from your runcommander.com dashboard.
   - Add `UPSTASH_REDIS_REST_URL` + `UPSTASH_REDIS_REST_TOKEN` for your tenant.
   - Add at least one of `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `GOOGLE_API_KEY`.
2. Start the service:
   ```sh
   sudo systemctl start commander-worker
   sudo systemctl status commander-worker
   ```
3. Confirm health (loopback only by default — `HOST=127.0.0.1`):
   ```sh
   curl -sSf -H "Authorization: Bearer $WORKER_SECRET" \
     http://127.0.0.1:7891/health
   ```
4. Tail logs:
   ```sh
   journalctl -u commander-worker -f
   ```

## Scope (v1)

| Feature | Status |
|---|---|
| Ubuntu 24.04 LTS | supported |
| Debian 12 / Ubuntu 22.04 | v1.1 |
| `uninstall.sh` | v1.4 (W4) |
| Cloudflare Tunnel auto-config | not yet (founder decision) |
| sshd lockdown / key rotation | v1.4 (W4) |
| Wizard UI / SSH orchestrator | v1.2 / v1.3 (W2 / W3) |

## Pinned version

This installer pins `WORKER_VERSION` at the top of [`install.sh`](./install.sh). Each commit to `main` ships one fixed worker version; upgrades land as a new commit + tag here.

## License

[MIT](./LICENSE)
