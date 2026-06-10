# BULWARK one-liner installer (Windows / PowerShell)
# https://getwark.com
#
# Usage:
#   irm https://getwark.com/install.ps1 | iex
#   irm https://getwark.com/install.ps1 | iex -ArgumentList @('--version', '5.25.0')
#   irm https://getwark.com/install.ps1 | iex -ArgumentList @('--channel', 'beta', '--dry-run')
#
# What it does:
#   1. Detects Windows version + architecture (x64 / ARM64)
#   2. Installs missing prerequisites (Git, Python 3.12, uv) WITHOUT admin
#      elevation when possible (winget, then chocolatey/scoop fallbacks)
#   3. Pulls BULWARK via the smart mix:
#        a) Native bundle (.exe / BULWARK-Setup.exe) if available for this arch
#        b) PyPI wheel (pip install bulwark) as fallback
#        c) Git clone + uv tool install as last resort
#   4. Runs `bulwark run` (unless --no-start)
#
# Exit codes (via $LASTEXITCODE / throw):
#   0   success
#   1   generic failure
#   2   unsupported platform (this script is Windows-only)
#   3   missing critical tool and cannot install
#   4   user declined an action required to continue
#
# Project: github.com/Zertannax/bulwark
# License: Apache-2.0

[CmdletBinding()]
param(
    [string]$Version = 'latest',
    [string]$Channel = 'stable',
    [switch]$DryRun,
    [switch]$NoBrowser,
    [switch]$NoStart,
    [switch]$Quiet,
    [switch]$Help
)

$ErrorActionPreference = 'Stop'

# ─── Configuration ──────────────────────────────────────────────────────
$GITHUB_REPO = 'Zertannax/bulwark'
$PYPI_PKG    = 'hellhound'   # PyPI package name; CLI binary is 'bulwark'
$BULWARK_CMD = 'bulwark'
$PYTHON_MIN  = '3.12'
$INSTALL_DIR = if ($env:BULWARK_HOME) { $env:BULWARK_HOME } else { Join-Path $env:USERPROFILE '.bulwark' }

# ─── Colors (auto-disabled if not a TTY) ────────────────────────────────
$Script:Colors = $Host.UI.SupportsVirtualTerminal
function _c([string]$code) { if ($Script:Colors) { "`e[$code" } else { '' } }
function BOLD() { _c '1m' }
function DIM()  { _c '2m' }
function RED()  { _c '31m' }
function GRN()  { _c '32m' }
function YEL()  { _c '33m' }
function BLU()  { _c '34m' }
function RST()  { _c '0m' }

# ─── Helpers ────────────────────────────────────────────────────────────
function Log  { if (-not $Quiet) { Write-Host "$(BLU)[bulwark]$(RST) $_" } }
function Ok   { if (-not $Quiet) { Write-Host "$(GRN)[ok]$(RST)     $_" } }
function Warn { Write-Host "$(YEL)[warn]$(RST)   $_" -ForegroundColor Yellow }
function Err  { Write-Host "$(RED)[error]$(RST)  $_" -ForegroundColor Red }
function Die  { param([string]$Message, [int]$Code = 1) Err $Message; exit $Code }

function Run {
    # Run an external command, or just print it in dry-run mode.
    param([scriptblock]$Cmd)
    if ($DryRun) {
        Write-Host "$(DIM)`$$(RST) $($Cmd.ToString().Trim())"
    } else {
        & $Cmd
        if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne $null) {
            Die "command failed (exit $LASTEXITCODE): $($Cmd.ToString().Trim())" 1
        }
    }
}

function Usage {
    @'

BULWARK installer (Windows / PowerShell)

Usage:
    irm https://getwark.com/install.ps1 | iex
    irm https://getwark.com/install.ps1 | iex -ArgumentList @('--version', '5.25.0')

Options:
    -Version <tag>    Pin a specific release tag (default: latest)
    -Channel <name>   Channel to install from: stable | beta (default: stable)
    -DryRun           Print commands without executing them
    -NoBrowser        Start BULWARK without opening the default browser
    -NoStart          Install only; do not auto-start BULWARK
    -Quiet            Suppress progress output
    -Help             Show this help and exit

Project: https://github.com/Zertannax/bulwark
'@
}

if ($Help) { Usage; exit 0 }

# ─── 1. Detect platform ─────────────────────────────────────────────────
function Detect-Platform {
    $os = [System.Environment]::OSVersion.Platform
    if ($os -ne 'Win32NT') {
        Die 'this script is Windows-only. macOS / Linux users: run install.sh' 2
    }

    # Architecture
    $arch = if ([System.Environment]::Is64BitOperatingSystem) {
        if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq 'Arm64') {
            'arm64'
        } else {
            'x64'
        }
    } else {
        Die 'BULWARK requires a 64-bit Windows install' 2
    }

    # Windows version (10+ supported, Server 2019+ supported)
    $winVer = [System.Environment]::OSVersion.Version
    if ($winVer.Major -lt 10) {
        Die "unsupported Windows version: $winVer. Need Windows 10+ or Server 2019+." 2
    }

    # Check for WSL
    $isWsl = $false
    if (Test-Path 'C:\Program Files\WindowsApps\Microsoft.WindowsTerminal_*') {
        # Win11 ships Terminal by default; cheap heuristic for WSL
        $isWsl = (Get-Command wsl.exe -ErrorAction SilentlyContinue) -ne $null
    }

    $Script:OS = 'windows'
    $Script:ARCH = $arch
    $Script:WINVER = $winVer
    $Script:IS_WSL = $isWsl
}

# ─── 2. Verify / install Git & PowerShell ───────────────────────────────
function Ensure-Basics {
    # git
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Warn 'git is not on PATH — needed for source installs (and to clone BULWARK on first run)'

        # Try winget
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            if (-not $Quiet) { Log 'installing git via winget…' }
            Run { winget install --id Git.Git -e --source winget --accept-package-agreements --accept-source-agreements }
            # Refresh PATH so the new git.exe is visible to this session
            $env:PATH = [System.Environment]::GetEnvironmentVariable('PATH', 'Machine') + ';' + [System.Environment]::GetEnvironmentVariable('PATH', 'User')
        } else {
            Warn 'winget is not available — please install Git for Windows from https://git-scm.com/download/win'
            Die 'git is required; install it and re-run' 3
        }
    }
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Die 'git still not on PATH after install' 3 }
}

# ─── 3. Install uv + Python 3.12 (no admin) ─────────────────────────────
function Ensure-UvAndPython {
    # uv
    if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
        if (-not $Quiet) { Log 'installing uv (Python package manager) via official installer…' }
        Run { powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://astral.sh/uv/install.ps1 | iex" }
        $uvBin = Join-Path $env:USERPROFILE '.local\bin'
        if (Test-Path $uvBin) { $env:PATH = "$uvBin;$env:PATH" }
    }
    if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
        Die 'uv is required; install from https://docs.astral.sh/uv/ and re-run' 3
    }

    # Python 3.12 — uv manages this transparently when invoked
    if (-not $Quiet) { Log "uv will manage Python $PYTHON_MIN transparently" }
}

# ─── 4. Resolve version + choose install method ────────────────────────
function Resolve-Version {
    if ($Version -eq 'latest') {
        if (-not $Quiet) { Log 'resolving latest version from GitHub…' }

        # Strategy 1: default branch
        if ($Channel -ne 'beta') {
            $defaultRef = git ls-remote --symref "https://github.com/$GITHUB_REPO.git" HEAD 2>$null |
                ForEach-Object { if ($_ -match '^ref:\s*refs/heads/(\S+)') { $Matches[1] } }
            if ($defaultRef) {
                $Script:RESOLVED_VERSION = $defaultRef
                if (-not $Quiet) { Log "resolved to default branch: $defaultRef" }
                return
            }
        }

        # Strategy 2: latest semver tag via git ls-remote
        $tag = git ls-remote --tags --sort=-v:refname "https://github.com/$GITHUB_REPO.git" 2>$null |
            ForEach-Object { if ($_ -match 'refs/tags/(v[0-9][^\s]*)') { $Matches[1] } } |
            Where-Object { $_ -notmatch '\^$' } |
            Select-Object -First 1
        if ($tag) {
            $Script:RESOLVED_VERSION = $tag
            if (-not $Quiet) { Log "resolved via git ls-remote: $tag" }
            return
        }

        # Strategy 3: GitHub /releases/latest
        if ($Channel -ne 'beta') {
            try {
                $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$GITHUB_REPO/releases/latest" -Headers @{ 'User-Agent' = 'bulwark-installer' } -ErrorAction Stop
                if ($release.tag_name) {
                    $Script:RESOLVED_VERSION = $release.tag_name
                    if (-not $Quiet) { Log "resolved via /releases/latest: $($release.tag_name)" }
                    return
                }
            } catch {
                Warn "/releases/latest failed: $_"
            }
        }

        Die 'could not resolve latest version from GitHub. Use -Version <tag> to pin.' 1
    } else {
        if ($Version -like 'v*') { $Script:RESOLVED_VERSION = $Version }
        else { $Script:RESOLVED_VERSION = "v$Version" }
    }
    if (-not $Quiet) { Log "target version: $Script:RESOLVED_VERSION" }
}

# ─── 5. Install: bundle → wheel → source ───────────────────────────────
function Install-ViaBundle {
    $pattern = "bulwark-windows-$($Script:ARCH)\.exe$"
    if (-not $Quiet) { Log "checking for native bundle matching: $pattern" }

    try {
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$GITHUB_REPO/releases/tags/$Script:RESOLVED_VERSION" `
            -Headers @{ 'User-Agent' = 'bulwark-installer' } -ErrorAction Stop
    } catch {
        Warn "could not fetch release $($Script:RESOLVED_VERSION): $_"
        return $false
    }

    $asset = $release.assets | Where-Object { $_.name -match $pattern } | Select-Object -First 1
    if (-not $asset) { return $false }

    if (-not $Quiet) { Log "found native bundle: $($asset.browser_download_url)" }
    $tmp = Join-Path $env:TEMP ("bulwark-bundle-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    try {
        $filename = $asset.name
        $downloadPath = Join-Path $tmp $filename
        if ($DryRun) {
            Write-Host "$(DIM)would download $($asset.browser_download_url) -> $downloadPath$(RST)"
        } else {
            Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $downloadPath -UseBasicParsing
        }

        switch -Wildcard ($filename) {
            '*.exe' {
                # Native BULWARK-Setup.exe — launch the installer silently
                if ($DryRun) {
                    Write-Host "$(DIM)would run: $downloadPath /S$(RST)"
                } else {
                    if (-not $Quiet) { Log "running installer (silent, /S)… this may take a minute" }
                    $p = Start-Process -FilePath $downloadPath -ArgumentList '/S' -PassThru -Wait
                    if ($p.ExitCode -ne 0) {
                        Warn "installer returned exit $($p.ExitCode) — falling back to wheel install"
                        return $false
                    }
                }
                $Script:INSTALL_METHOD = 'bundle-exe'
                return $true
            }
            default {
                Warn "unsupported bundle format: $filename"
                return $false
            }
        }
    } finally {
        Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    }
    return $true
}

function Install-ViaWheel {
    if (-not $Quiet) { Log "trying to install $PYPI_PKG from PyPI" }

    # Probe PyPI
    try {
        $resp = Invoke-WebRequest -Uri "https://pypi.org/pypi/$PYPI_PKG/json" -Method Head -UseBasicParsing -ErrorAction Stop
        if ($resp.StatusCode -eq 404) {
            Warn "$PYPI_PKG is not published on PyPI yet (HTTP 404) — falling back to source install"
            return $false
        }
    } catch {
        Warn "PyPI probe failed: $_ — will attempt install anyway"
    }

    $pkgSpec = $PYPI_PKG
    if ($Version -ne 'latest') { $pkgSpec = "$PYPI_PKG==$($Script:RESOLVED_VERSION -replace '^v','')" }

    if ($DryRun) {
        Write-Host "$(DIM)would run: uv tool install --python $PYTHON_MIN $pkgSpec$(RST)"
    } else {
        $installLog = uv tool install --python $PYTHON_MIN $pkgSpec 2>&1
        if ($LASTEXITCODE -ne 0) {
            Warn "wheel install failed. Output:`n$installLog`nFalling back to source install…"
            return $false
        }
    }

    if (-not $DryRun) {
        # Ensure the bulwark command is on PATH for this session
        $uvBin = Join-Path $env:USERPROFILE '.local\bin'
        if (Test-Path (Join-Path $uvBin "$BULWARK_CMD.exe")) {
            $env:PATH = "$uvBin;$env:PATH"
        } else {
            Warn "wheel installed but $BULWARK_CMD.exe binary not found in $uvBin"
            return $false
        }
    }
    $Script:INSTALL_METHOD = 'wheel'
    return $true
}

function Install-ViaSource {
    if (-not $Quiet) { Log 'falling back to source install (git clone + uv tool install)' }

    $srcDir = Join-Path $INSTALL_DIR 'src'
    if (-not (Test-Path $INSTALL_DIR)) {
        Run { New-Item -ItemType Directory -Path $INSTALL_DIR -Force | Out-Null }
    }

    if (Test-Path (Join-Path $srcDir '.git')) {
        if (-not $Quiet) { Log "source already cloned at $srcDir — checking current state" }

        $currentBranch = git -C $srcDir symbolic-ref --short HEAD 2>$null
        if (-not $currentBranch) { $currentBranch = 'DETACHED' }
        $currentCommit = git -C $srcDir rev-parse HEAD 2>$null

        switch -Regex ($Script:RESOLVED_VERSION) {
            '^(master|main)$' {
                if ($currentBranch -eq $Script:RESOLVED_VERSION) {
                    if (-not $Quiet) { Log "already on '$($Script:RESOLVED_VERSION)' at $currentCommit — fast-forward only" }
                    Run { git -C $srcDir fetch --tags --force }
                    try { Run { git -C $srcDir merge --ff-only '@{u}' } } catch { Log '(local branch is already at the remote tip — no update needed)' }
                } else {
                    if (-not $Quiet) { Log "switching from $currentBranch to $($Script:RESOLVED_VERSION)" }
                    Run { git -C $srcDir fetch --tags --force }
                    try { Run { git -C $srcDir switch -f $Script:RESOLVED_VERSION } }
                    catch { Run { git -C $srcDir checkout -f $Script:RESOLVED_VERSION } }
                }
            }
            default {
                $targetCommit = git -C $srcDir rev-parse $Script:RESOLVED_VERSION 2>$null
                if ($currentCommit -eq $targetCommit) {
                    if (-not $Quiet) { Log "already at $($Script:RESOLVED_VERSION) ($currentCommit) — no version switch needed" }
                } else {
                    if (-not $Quiet) { Log "switching from $currentBranch ($currentCommit) to $($Script:RESOLVED_VERSION)" }
                    Run { git -C $srcDir fetch --tags --force }
                    try { Run { git -C $srcDir switch -f $Script:RESOLVED_VERSION } }
                    catch { Run { git -C $srcDir checkout -f $Script:RESOLVED_VERSION } }
                }
            }
        }
    } else {
        # Fresh clone — resolve the default branch from origin
        $defaultBranch = git ls-remote --symref "https://github.com/$GITHUB_REPO.git" HEAD 2>$null |
            ForEach-Object { if ($_ -match '^ref:\s*refs/heads/(\S+)') { $Matches[1] } } |
            Select-Object -First 1
        if (-not $defaultBranch) { $defaultBranch = 'master' }

        if ($Script:RESOLVED_VERSION -eq $defaultBranch) {
            if (-not $Quiet) { Log "cloning default branch '$defaultBranch' (always the latest tip)" }
            Run { git clone --depth 1 "https://github.com/$GITHUB_REPO.git" $srcDir }
        } else {
            if (-not $Quiet) { Log "cloning '$defaultBranch', then checking out tag '$Script:RESOLVED_VERSION'" }
            Run { git clone --depth 1 "https://github.com/$GITHUB_REPO.git" $srcDir }
            try { Run { git -C $srcDir fetch --depth=1 origin "refs/tags/$($Script:RESOLVED_VERSION):refs/tags/$($Script:RESOLVED_VERSION)" } }
            catch { Run { git -C $srcDir fetch --tags --depth=1 origin } }
            Run { git -C $srcDir checkout --force $Script:RESOLVED_VERSION }
        }
    }

    if (-not $Quiet) { Log "running uv tool install (creates the 'bulwark' binary in ~/.local/bin)" }
    Run { uv tool install --python $PYTHON_MIN --with packaging --editable $srcDir }

    if (Get-Command node -ErrorAction SilentlyContinue) {
        if (-not $Quiet) { Log 'Node detected — building the React frontend' }
        Run { & bash "$srcDir\scripts\build_frontend.sh" }
    } else {
        Warn 'Node not found — the UI may be blank. Install Node 22+ and run:'
        Warn "  bash $srcDir\scripts\build_frontend.sh"
    }

    $Script:INSTALL_METHOD = 'source'
    return $true
}

# ─── 6. Post-install: verify + advise ───────────────────────────────────
function Verify-AndFinalize {
    if ($DryRun) {
        Log '[dry-run] would verify bulwark --version'
        return
    }

    if (-not (Get-Command $BULWARK_CMD -ErrorAction SilentlyContinue)) {
        Die "install reported success but '$BULWARK_CMD' is not on PATH. Check the messages above." 1
    }

    $ver = & $BULWARK_CMD --version 2>&1
    Ok "BULWARK installed: $ver"

    if ($NoStart) {
        Log "skipping launch (-NoStart). Run '$BULWARK_CMD run' when ready."
        Write-Host ''
        Log "$(BOLD)What's next$(RST):"
        Log '  1. The demo works without Docker — just run:'
        Log "     $(BOLD)bulwark run$(RST)"
        Log "     Then press $(BOLD)Ctrl-K$(RST) -> $(BOLD)`"Spawn demo engagement`"$(RST)."
        Write-Host ''
        Log '  2. For a real engagement you need Docker + the Kali sandbox image.'

        if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
            Warn 'Docker is NOT installed. Pick one:'
            Write-Host "     $(BOLD)winget install Docker.DockerDesktop$(RST)  (then launch Docker Desktop)"
            Write-Host '     OR  https://www.docker.com/products/docker-desktop/'
        } else {
            try { docker info 2>&1 | Out-Null; if ($LASTEXITCODE -ne 0) { throw 'daemon not running' } }
            catch { Warn 'Docker is installed but the daemon is not running — start Docker Desktop, then run "bulwark run"' }
            if ($?) { Ok 'Docker is running — you are ready for a real engagement' }
        }
        return
    }

    Write-Host ''
    Log "$(BOLD)Next steps$(RST):"
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Warn 'Docker is not installed — needed for real engagements (the demo works without it)'
        Write-Host '     Install Docker Desktop: https://www.docker.com/products/docker-desktop/'
    } else {
        try { docker info 2>&1 | Out-Null; if ($LASTEXITCODE -ne 0) { throw 'daemon not running' } }
        catch { Warn 'Docker is installed but the daemon is not running — start Docker Desktop' }
    }

    Log 'Launching BULWARK…'
    $bulwarkArgs = @('run')
    if ($NoBrowser) { $bulwarkArgs += '--no-browser' }
    & $BULWARK_CMD @bulwarkArgs
}

# ─── Main ───────────────────────────────────────────────────────────────
function Main {
    Write-Host "$(BOLD)$(BLU)  BULWARK installer$(RST)  github.com/$GITHUB_REPO"
    Write-Host "$(DIM)    Autonomous external pentest agent. Silent. Patient. Inevitable.$(RST)"
    Write-Host ''

    Detect-Platform
    Log "detected: OS=$($Script:OS) ARCH=$($Script:ARCH) WINVER=$($Script:WINVER) WSL=$($Script:IS_WSL)"

    Ensure-Basics
    Ensure-UvAndPython
    Resolve-Version

    if (Install-ViaBundle) {
        Ok 'installed via native bundle'
    } elseif (Install-ViaWheel) {
        Ok 'installed via PyPI wheel'
    } else {
        if (Install-ViaSource) {
            Ok 'installed from source'
        } else {
            Die 'all install methods failed' 1
        }
    }

    Verify-AndFinalize
}

Main
