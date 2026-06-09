# BULWARK Installers

> One-line installers for [BULWARK](https://github.com/Zertannax/bulwark).
> Mirrored automatically from `Zertannax/bulwark@master:scripts/install.sh`.

## Install

**macOS / Linux:**

```bash
curl -fsSL https://getwark.com/install.sh | bash
```

(Aliases: `https://getwark.com/install.sh` · `https://install.getwark.com/install.sh`)

## What this repo is

This is a **delivery channel**, not the source of truth. The canonical
installer lives at `Zertannax/bulwark/scripts/install.sh` and is mirrored
here on every push via `.github/workflows/sync-installers.yml`.

The mirror is served by **Cloudflare Pages** on the `bulwark-install` project
and fronted by the `getwark.com` / `install.getwark.com` custom domain.

## Files

| File | Source | Purpose |
|---|---|---|
| `scripts/install.sh` | `bulwark/scripts/install.sh` | POSIX installer (macOS, Linux, WSL) |
| `scripts/install.ps1` | `bulwark/scripts/install.ps1` | PowerShell installer (Windows) |

## License

Apache-2.0 — see [LICENSE](./LICENSE).
