#!/usr/bin/env bash
# BULWARK one-liner installer
# https://getwark.com
#
# Usage:
#   curl -fsSL https://getwark.com/install.sh | bash
#   curl -fsSL https://getwark.com/install.sh | bash -s -- --version 5.25.0
#   curl -fsSL https://getwark.com/install.sh | bash -s -- --channel beta --dry-run
#
# What it does:
#   1. Detects OS (macOS / Linux / WSL) and architecture (x86_64 / arm64)
#   2. Installs missing prerequisites (uv, Python 3.12) without sudo
#   3. Pulls BULWARK via the smart mix:
#        a) Native bundle (AppImage/.deb/.exe) if available for this OS/arch
#        b) PyPI wheel (pip install bulwark) as fallback
#        c) Git clone + uv sync as last resort
#   4. Runs `bulwark run` and opens the browser
#
# Exit codes:
#   0   success (BULWARK installed and started)
#   1   generic failure
#   2   unsupported platform (e.g. OpenBSD, no WSL)
#   3   missing critical tool (curl, git) and cannot install
#   4   user declined an action that was required to continue
#
# Project: github.com/Zertannax/bulwark
# License: Apache-2.0

set -euo pipefail

# ─── Configuration ──────────────────────────────────────────────────────
GITHUB_REPO="Zertannax/bulwark"
PYPI_PKG="hellhound"      # PyPI package name (CLI binary is `bulwark`)
BULWARK_CMD="bulwark"
PYTHON_MIN="3.12"
INSTALL_DIR="${BULWARK_HOME:-$HOME/.bulwark}"
VERSION="latest"
CHANNEL="stable"
DRY_RUN=0
NO_BROWSER=0
NO_START=0
QUIET=0

# Colors (auto-disabled if not a TTY)
if [ -t 1 ] && command -v tput >/dev/null 2>&1; then
    C_BOLD=$(tput bold 2>/dev/null || true)
    C_RED=$(tput setaf 1 2>/dev/null || true)
    C_GRN=$(tput setaf 2 2>/dev/null || true)
    C_YEL=$(tput setaf 3 2>/dev/null || true)
    C_BLU=$(tput setaf 4 2>/dev/null || true)
    C_DIM=$(tput dim 2>/dev/null || true)
    C_RST=$(tput sgr0 2>/dev/null || true)
else
    C_BOLD=""; C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_DIM=""; C_RST=""
fi

# ─── Helpers ────────────────────────────────────────────────────────────
log()  { [ "$QUIET" -eq 1 ] && return 0; printf "%s[bulwark]%s %s\n" "$C_BLU" "$C_RST" "$*"; }
ok()   { [ "$QUIET" -eq 1 ] && return 0; printf "%s[ok]%s     %s\n" "$C_GRN" "$C_RST" "$*"; }
warn() { printf "%s[warn]%s   %s\n" "$C_YEL" "$C_RST" "$*" >&2; }
err()  { printf "%s[error]%s  %s\n" "$C_RED" "$C_RST" "$*" >&2; }
die()  { err "$*"; exit "${2:-1}"; }

run() {
    # Run a command, or just print it in dry-run mode
    if [ "$DRY_RUN" -eq 1 ]; then
        printf "%s\$%s %s\n" "$C_DIM" "$C_RST" "$*"
    else
        "$@"
    fi
}

usage() {
    cat <<EOF
BULWARK installer

Usage:
    curl -fsSL https://getwark.com/install.sh | bash
    curl -fsSL https://getwark.com/install.sh | bash -s -- [options]

Options:
    --version VER     Install a specific version (e.g. 5.25.0). Default: latest
    --channel CHAN    Release channel: stable | beta. Default: stable
    --dir PATH        Install location (default: \$HOME/.bulwark)
    --no-browser      Don't open the browser after install
    --no-start        Install only, don't run the agent
    --dry-run         Print commands without executing them
    -q, --quiet       Suppress non-error output
    -h, --help        Show this help

Environment:
    BULWARK_HOME      Override the install directory
    BULWARK_NO_BROWSER=1   Same as --no-browser
    BULWARK_NO_START=1     Same as --no-start
EOF
}

# ─── Argument parsing ───────────────────────────────────────────────────
while [ $# -gt 0 ]; do
    case "$1" in
        --version)  VERSION="$2"; shift 2 ;;
        --channel)  CHANNEL="$2"; shift 2 ;;
        --dir)      INSTALL_DIR="$2"; shift 2 ;;
        --no-browser) NO_BROWSER=1; shift ;;
        --no-start) NO_START=1; shift ;;
        --dry-run)  DRY_RUN=1; shift ;;
        -q|--quiet) QUIET=1; shift ;;
        -h|--help)  usage; exit 0 ;;
        *)
            die "unknown option: $1 (use --help)"
            ;;
    esac
done

[ -n "${BULWARK_NO_BROWSER:-}" ] && NO_BROWSER=1
[ -n "${BULWARK_NO_START:-}" ] && NO_START=1

# ─── 1. Detect platform ────────────────────────────────────────────────
detect_platform() {
    OS="unknown"
    DISTRO="unknown"
    ARCH="unknown"
    IS_WSL=0

    case "$(uname -m 2>/dev/null || echo unknown)" in
        x86_64|amd64)   ARCH="x86_64" ;;
        aarch64|arm64)  ARCH="arm64" ;;
        i386|i686)      ARCH="x86" ;;
        *)              die "unsupported architecture: $(uname -m)" 2 ;;
    esac

    case "$(uname -s 2>/dev/null || echo unknown)" in
        Linux)
            OS="linux"
            if [ -r /proc/version ] && grep -qiE "microsoft|wsl" /proc/version 2>/dev/null; then
                IS_WSL=1
            fi
            if [ -r /etc/os-release ]; then
                # shellcheck disable=SC1091
                . /etc/os-release
                DISTRO="${ID:-unknown}"
            elif command -v lsb_release >/dev/null 2>&1; then
                DISTRO="$(lsb_release -si | tr '[:upper:]' '[:lower:]')"
            fi
            ;;
        Darwin)
            OS="macos"
            if command -v sw_vers >/dev/null 2>&1; then
                MACOS_VER="$(sw_vers -productVersion)"
                case "$MACOS_VER" in
                    10.*) DISTRO="macos-legacy" ;;
                    11.*) DISTRO="macos-bigsur" ;;
                    12.*) DISTRO="macos-monterey" ;;
                    13.*) DISTRO="macos-ventura" ;;
                    14.*) DISTRO="macos-sonoma" ;;
                    15.*) DISTRO="macos-sequoia" ;;
                    *)    DISTRO="macos-newer" ;;
                esac
            else
                DISTRO="macos-unknown"
            fi
            ;;
        MINGW*|MSYS*|CYGWIN*)
            die "this script is POSIX — Windows users: run install.ps1 from PowerShell" 2
            ;;
        *)
            die "unsupported OS: $(uname -s)" 2
            ;;
    esac
}

# ─── 2. Verify / install curl & git ────────────────────────────────────
ensure_basics() {
    local missing=()
    command -v curl >/dev/null 2>&1 || missing+=("curl")
    command -v git   >/dev/null 2>&1 || missing+=("git")

    if [ ${#missing[@]} -eq 0 ]; then
        return 0
    fi

    warn "missing required tools: ${missing[*]}"

    case "$OS" in
        macos)
            if command -v brew >/dev/null 2>&1; then
                log "installing via Homebrew: ${missing[*]}"
                run brew install "${missing[@]}"
            else
                die "missing ${missing[*]} and Homebrew is not installed. Install Homebrew first: https://brew.sh" 3
            fi
            ;;
        linux)
            if command -v apt-get >/dev/null 2>&1; then
                log "installing via apt: ${missing[*]}"
                run sudo apt-get update
                run sudo apt-get install -y "${missing[@]}"
            elif command -v dnf >/dev/null 2>&1; then
                run sudo dnf install -y "${missing[@]}"
            elif command -v yum >/dev/null 2>&1; then
                run sudo yum install -y "${missing[@]}"
            elif command -v pacman >/dev/null 2>&1; then
                run sudo pacman -S --noconfirm "${missing[@]}"
            elif command -v apk >/dev/null 2>&1; then
                run sudo apk add --no-cache "${missing[@]}"
            elif command -v zypper >/dev/null 2>&1; then
                run sudo zypper install -y "${missing[@]}"
            else
                die "missing ${missing[*]} and no supported package manager found. Install them manually first." 3
            fi
            ;;
    esac

    local still_missing=()
    command -v curl >/dev/null 2>&1 || still_missing+=("curl")
    command -v git   >/dev/null 2>&1 || still_missing+=("git")
    if [ ${#still_missing[@]} -gt 0 ]; then
        die "still missing: ${still_missing[*]} after install" 3
    fi
    ok "curl & git present"
}

# ─── 3. Install uv + Python 3.12 (no sudo) ─────────────────────────────
ensure_uv_and_python() {
    if ! command -v uv >/dev/null 2>&1; then
        log "installing uv (Astral's Python package manager) — no sudo needed"
        run curl -LsSf https://astral.sh/uv/install.sh | sh
        UV_BIN="$HOME/.local/bin"
        if [ -x "$UV_BIN/uv" ]; then
            export PATH="$UV_BIN:$PATH"
        fi
        warn "uv installed at $UV_BIN/uv — add it to your shell rc if not already:"
        warn '  export PATH="$HOME/.local/bin:$PATH"'
    else
        ok "uv $(uv --version 2>/dev/null || echo 'present')"
    fi

    if uv python find "$PYTHON_MIN" >/dev/null 2>&1; then
        ok "Python $PYTHON_MIN available"
    else
        log "downloading Python $PYTHON_MIN (uv handles this — no system Python needed)"
        run uv python install "$PYTHON_MIN"
    fi
}

# ─── 4. Resolve version + choose install method ────────────────────────
resolve_version() {
    # Resolve "latest" to a concrete branch or tag.
    #
    #   1. Default branch (master/main) — BULWARK ships new commits to
    #      the default branch faster than it tags releases.
    #   2. Most recent semver tag (sorted desc).
    #   3. GitHub API as last resort.
    if [ "$VERSION" = "latest" ]; then
        if [ "$DRY_RUN" -eq 1 ]; then
            RESOLVED_VERSION="master"
            log "[dry-run] would query GitHub for latest release"
            return 0
        fi

        log "resolving latest version from GitHub"
        local tag=""

        # Strategy 1: default branch
        if [ "$CHANNEL" != "beta" ]; then
            tag="$(git ls-remote --symref "https://github.com/$GITHUB_REPO.git" HEAD 2>/dev/null \
                | awk '/^ref:/ {print $2}' | sed 's#refs/heads/##' || true)"
            if [ -n "$tag" ]; then
                log "resolved to default branch: $tag"
                RESOLVED_VERSION="$tag"
                return 0
            fi
        fi

        # Strategy 2: latest semver tag
        local raw
        raw="$(git ls-remote --tags --sort=-v:refname \
            "https://github.com/$GITHUB_REPO.git" 2>&1 || true)"
        if [ -n "${BULWARK_DEBUG:-}" ]; then
            log "[debug] git ls-remote raw output:"
            printf '%s\n' "$raw" | sed 's/^/    /'
        fi
        tag="$(printf '%s\n' "$raw" \
            | awk '{print $2}' \
            | sed -e 's#refs/tags/##' -e '/\^{}$/d' \
            | grep -E '^v[0-9]' \
            | head -1)"

        if [ -n "$tag" ]; then
            log "resolved via git ls-remote: $tag"
            RESOLVED_VERSION="$tag"
            return 0
        fi
        warn "git ls-remote returned no usable tag — trying GitHub API"

        # Strategy 3: GitHub releases/latest
        if [ "$CHANNEL" != "beta" ]; then
            tag="$(curl -fsSL "https://api.github.com/repos/$GITHUB_REPO/releases/latest" 2>/dev/null \
                | grep -m1 '"tag_name"' \
                | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/' || true)"
            if [ -n "$tag" ]; then
                log "resolved via /releases/latest: $tag"
                RESOLVED_VERSION="$tag"
                return 0
            fi
        fi

        # Strategy 4: GitHub /tags (rate-limited)
        tag="$(curl -fsSL "https://api.github.com/repos/$GITHUB_REPO/tags?per_page=1" 2>/dev/null \
            | grep -oE '"name"[[:space:]]*:[[:space:]]*"v[^"]+"' \
            | head -1 \
            | sed -E 's/.*"([^"]+)".*/\1/' || true)"

        if [ -n "$tag" ]; then
            log "resolved via /tags: $tag"
            RESOLVED_VERSION="$tag"
            return 0
        fi

        die "could not resolve latest version from GitHub. Use --version to pin a specific tag." 1
    else
        case "$VERSION" in
            v*) RESOLVED_VERSION="$VERSION" ;;
            *)  RESOLVED_VERSION="v$VERSION" ;;
        esac
    fi
    log "target version: $RESOLVED_VERSION"
}

# ─── 5. Install: bundle → wheel → source ────────────────────────────────
install_via_bundle() {
    local pattern
    case "$OS" in
        macos)  pattern="bulwark-macos-$ARCH\.(dmg|pkg|zip)" ;;
        linux)  pattern="bulwark-linux-$ARCH\.(AppImage|deb|rpm)" ;;
        *)      return 1 ;;
    esac

    log "checking for native bundle matching: $pattern"
    local api_url="https://api.github.com/repos/$GITHUB_REPO/releases/tags/$RESOLVED_VERSION"
    local asset_url
    asset_url="$(curl -fsSL "$api_url" 2>/dev/null \
        | grep -oE "\"browser_download_url\"[[:space:]]*:[[:space:]]*\"[^\"]*${pattern//\./\\.}\"" \
        | head -1 \
        | sed -E 's/.*"([^"]+)".*/\1/' || true)"

    if [ -z "$asset_url" ]; then
        return 1
    fi

    log "found native bundle: $asset_url"
    local tmp
    tmp="$(mktemp -d)"
    local filename
    filename="$(basename "$asset_url")"

    if [ "$DRY_RUN" -eq 0 ]; then
        curl -fL#o "$tmp/$filename" "$asset_url"
        case "$filename" in
            *.AppImage)
                mkdir -p "$INSTALL_DIR/bin"
                install -m 0755 "$tmp/$filename" "$INSTALL_DIR/bin/$BULWARK_CMD"
                INSTALL_METHOD="bundle-appimage"
                ;;
            *.deb)
                run sudo dpkg -i "$tmp/$filename" || run sudo apt-get install -fy
                INSTALL_METHOD="bundle-deb"
                ;;
            *.rpm)
                run sudo rpm -i "$tmp/$filename" || run sudo dnf install -y "$tmp/$filename"
                INSTALL_METHOD="bundle-rpm"
                ;;
            *.dmg)
                warn "DMG install is not yet automated — please mount and drag BULWARK.app to /Applications"
                INSTALL_METHOD="bundle-dmg-manual"
                ;;
            *)
                warn "unsupported bundle format: $filename"
                rm -rf "$tmp"
                return 1
                ;;
        esac
        rm -rf "$tmp"
    fi
    return 0
}

install_via_wheel() {
    log "trying to install $PYPI_PKG from PyPI"

    local pypi_status
    pypi_status="$(curl -fsSL -o /dev/null -w '%{http_code}' \
        "https://pypi.org/pypi/$PYPI_PKG/json" 2>/dev/null)"
    [ -z "$pypi_status" ] && pypi_status="000"

    if [ "$pypi_status" = "404" ]; then
        warn "$PYPI_PKG is not published on PyPI yet (HTTP 404) — falling back to source install"
        return 1
    elif [ "$pypi_status" != "200" ]; then
        warn "PyPI probe returned HTTP $pypi_status — will attempt install anyway"
    fi

    local py_args=()
    if command -v uv >/dev/null 2>&1; then
        py_args=(uv tool install --python "$PYTHON_MIN")
        [ "$VERSION" != "latest" ] && py_args+=("$PYPI_PKG==${RESOLVED_VERSION#v}")
    else
        py_args=(python3 -m pip install --user)
        [ "$VERSION" != "latest" ] && py_args+=("$PYPI_PKG==${RESOLVED_VERSION#v}")
    fi

    if [ "$DRY_RUN" -eq 0 ]; then
        local install_log
        install_log="$("${py_args[@]}" "$PYPI_PKG" 2>&1)" \
            || die "wheel install failed. Output:\n$install_log\n\nFalling back to source install..." 1
    fi

    if [ "$DRY_RUN" -eq 0 ] && ! command -v "$BULWARK_CMD" >/dev/null 2>&1; then
        warn "$BULWARK_CMD is not on PATH yet — checking uv tool bin"
        local uv_bin
        uv_bin="$(uv tool dir 2>/dev/null)/bin"
        if [ -x "$uv_bin/$BULWARK_CMD" ]; then
            export PATH="$uv_bin:$PATH"
            warn "add $uv_bin to your PATH for future shells"
        else
            warn "wheel installed but $BULWARK_CMD binary not found in uv tool dir"
            return 1
        fi
    fi
    INSTALL_METHOD="wheel"
    return 0
}

install_via_source() {
    log "falling back to source install (git clone + uv sync)"

    local src_dir="$INSTALL_DIR/src"
    run mkdir -p "$INSTALL_DIR"

    if [ -d "$src_dir/.git" ]; then
        log "source already cloned at $src_dir — checking current state"

        # What's the current state?
        local current_branch
        current_branch="$(git -C "$src_dir" symbolic-ref --short HEAD 2>/dev/null || echo "DETACHED")"
        local current_commit
        current_commit="$(git -C "$src_dir" rev-parse HEAD 2>/dev/null)"

        # If we're on the target version already (or master, when target is
        # "master" / "latest"), just update the remote refs and call it
        # done. Crucially: do NOT run `git checkout` — it would clobber any
        # local edits like a patched build_frontend.sh. We then fall through
        # to the package install step below.
        case "$RESOLVED_VERSION" in
            master|main)
                if [ "$current_branch" = "$RESOLVED_VERSION" ]; then
                    log "already on '$RESOLVED_VERSION' at $current_commit — fast-forward only"
                    run git -C "$src_dir" fetch --tags --force
                    # Fast-forward merge origin/<branch> into the current branch
                    # without touching the working tree. If we're already at
                    # the tip, this is a no-op.
                    run git -C "$src_dir" merge --ff-only "@{u}" 2>/dev/null || \
                        log "(local branch is already at the remote tip — no update needed)"
                else
                    log "switching from $current_branch to $RESOLVED_VERSION"
                    run git -C "$src_dir" fetch --tags --force
                    run git -C "$src_dir" switch -f "$RESOLVED_VERSION" \
                        || run git -C "$src_dir" checkout -f "$RESOLVED_VERSION"
                fi
                ;;
            *)
                # Pinned version — check if HEAD already points at it.
                if [ "$current_commit" = "$(git -C "$src_dir" rev-parse "$RESOLVED_VERSION" 2>/dev/null)" ]; then
                    log "already at $RESOLVED_VERSION ($current_commit) — no version switch needed"
                else
                    log "switching from $current_branch ($current_commit) to $RESOLVED_VERSION"
                    run git -C "$src_dir" fetch --tags --force
                    run git -C "$src_dir" switch -f "$RESOLVED_VERSION" \
                        || run git -C "$src_dir" checkout -f "$RESOLVED_VERSION"
                fi
                ;;
        esac
    else
        # Fresh clone — resolve the default branch from origin
        local default_branch
        default_branch="$(git ls-remote --symref "https://github.com/$GITHUB_REPO.git" HEAD 2>/dev/null \
            | awk '/^ref:/ {print $2}' | sed 's#refs/heads/##' || true)"
        [ -z "$default_branch" ] && default_branch="master"

        if [ "$RESOLVED_VERSION" = "$default_branch" ]; then
            log "cloning default branch '$default_branch' (always the latest tip)"
            run git clone --depth 1 "https://github.com/$GITHUB_REPO.git" "$src_dir"
        else
            log "cloning '$default_branch', then checking out tag '$RESOLVED_VERSION'"
            run git clone --depth 1 "https://github.com/$GITHUB_REPO.git" "$src_dir"
            run git -C "$src_dir" fetch --depth=1 origin \
                "refs/tags/$RESOLVED_VERSION:refs/tags/$RESOLVED_VERSION" \
                || run git -C "$src_dir" fetch --tags --depth=1 origin
            run git -C "$src_dir" checkout --force "$RESOLVED_VERSION"
        fi
    fi

    log "running uv tool install (creates the 'bulwark' binary in ~/.local/bin)"
    # `--with packaging` covers a transitive dep (pydantic → packaging)
    # that some distros' uv tool venv omits on first install. The
    # explicit dep is harmless when packaging is already present.
    run uv tool install --python "$PYTHON_MIN" --with packaging --editable "$src_dir"

    if command -v node >/dev/null 2>&1; then
        log "Node detected — building the React frontend"
        run bash "$src_dir/scripts/build_frontend.sh"
    else
        warn "Node not found — the UI may be blank. Install Node 22+ and run:"
        warn "  bash $src_dir/scripts/build_frontend.sh"
    fi

    INSTALL_METHOD="source"
    return 0
}

# ─── 6. Post-install: verify + advise ──────────────────────────────────
verify_and_finalize() {
    if [ "$DRY_RUN" -eq 1 ]; then
        log "[dry-run] would verify $BULWARK_CMD --version"
        return 0
    fi

    if ! command -v "$BULWARK_CMD" >/dev/null 2>&1; then
        die "install reported success but '$BULWARK_CMD' is not on PATH. Check the messages above." 1
    fi

    local ver
    ver="$($BULWARK_CMD --version 2>&1 || true)"
    ok "BULWARK installed: $ver"

    if [ "$NO_START" -eq 1 ]; then
        log "skipping launch (--no-start). Run '$BULWARK_CMD run' when ready."
        printf "\n"
        log "${C_BOLD}What's next${C_RST}:"
        log "  1. The demo works without Docker — just run:"
        log "     ${C_BOLD}bulwark run${C_RST}"
        log "     Then press ${C_BOLD}⌘K / Ctrl-K${C_RST} → ${C_BOLD}\"Spawn demo engagement\"${C_RST}."
        log ""
        log "  2. For a real engagement you need Docker + the Kali sandbox image."
        if ! command -v docker >/dev/null 2>&1; then
            warn "Docker is NOT installed. Pick your platform:"
            case "$OS" in
                macos)
                    log "     macOS: ${C_BOLD}brew install --cask docker${C_RST}  (then launch Docker Desktop)"
                    log "            OR  https://www.docker.com/products/docker-desktop/"
                    ;;
                linux)
                    log "     Linux: ${C_BOLD}curl -fsSL https://get.docker.com | sh${C_RST}"
                    log "            (then add yourself to the docker group: sudo usermod -aG docker \$USER)"
                    log "            OR  https://docs.docker.com/engine/install/"
                    ;;
                *)
                    log "     See https://docs.docker.com/engine/install/"
                    ;;
            esac
        elif ! docker info >/dev/null 2>&1; then
            warn "Docker is installed but the daemon is not running — start it, then run 'bulwark run'"
        else
            ok "Docker is running — you're ready for a real engagement"
            log "     The Kali sandbox image (~2.2 GB) auto-pulls on your first real run."
        fi
        return 0
    fi

    printf "\n"
    log "${C_BOLD}Next steps${C_RST}:"
    if ! command -v docker >/dev/null 2>&1; then
        warn "Docker is not installed — needed for real engagements (the demo works without it)"
        case "$OS" in
            macos)  warn "  Install Docker Desktop: https://www.docker.com/products/docker-desktop/" ;;
            linux)  warn "  Install Docker Engine: https://docs.docker.com/engine/install/" ;;
        esac
    elif ! docker info >/dev/null 2>&1; then
        warn "Docker is installed but the daemon is not running — start Docker Desktop / the engine"
    fi

    log "Launching BULWARK..."
    local args=(run)
    [ "$NO_BROWSER" -eq 1 ] && args+=(--no-browser)

    exec "$BULWARK_CMD" "${args[@]}"
}

# ─── Main ───────────────────────────────────────────────────────────────
main() {
    printf "%s%s  BULWARK installer%s  github.com/%s\n" "$C_BOLD" "$C_BLU" "$C_RST" "$GITHUB_REPO"
    printf "%s    Autonomous external pentest agent. Silent. Patient. Inevitable.%s\n\n" "$C_DIM" "$C_RST"

    detect_platform
    log "detected: OS=$OS DISTRO=$DISTRO ARCH=$ARCH WSL=$IS_WSL"

    ensure_basics
    ensure_uv_and_python
    resolve_version

    if install_via_bundle; then
        ok "installed via native bundle"
    elif install_via_wheel; then
        ok "installed via PyPI wheel"
    else
        install_via_source
        ok "installed from source"
    fi

    verify_and_finalize
}

main "$@"
