#!/usr/bin/env bash
# ============================================================
#  palazikBox - Setup Script
#  Installs all required dependencies for cos_toolbox.sh
#  Supports: Arch Linux, Debian, Ubuntu, Android (and derivatives)
# ============================================================

set -euo pipefail

# ── Colors ───────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

ok()   { echo -e "${GREEN}✓${NC} $*"; }
err()  { echo -e "${RED}✗${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC} $*"; }
info() { echo -e "${CYAN}▶${NC} $*"; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOOLS_DIR="$SCRIPT_DIR/tools"

# ── Detect environment ───────────────────────────────────────
IS_ANDROID=false
if [[ -n "${TERMUX_VERSION:-}" ]] || [[ -d "/data/data/com.termux" ]]; then
    IS_ANDROID=true
fi

# ── Detect distro ─────────────────────────────────────────────
detect_distro() {
    if [[ "$IS_ANDROID" == true ]]; then
        echo "termux"
        return
    fi
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        echo "${ID,,}"
    elif command -v pacman &>/dev/null; then
        echo "arch"
    elif command -v apt-get &>/dev/null; then
        echo "debian"
    else
        echo "unknown"
    fi
}

# ── Detect base family ────────────────────────────────────────
detect_family() {
    local id="$1"
    case "$id" in
        termux)                                    echo "termux" ;;
        arch|manjaro|endeavouros|garuda)           echo "arch" ;;
        debian|ubuntu|linuxmint|pop|kali|zorin|elementary) echo "debian" ;;
        *) echo "unknown" ;;
    esac
}

# ── Print banner ──────────────────────────────────────────────
echo ""
echo -e "${BOLD}============================================================${NC}"
echo -e "${BOLD}         palazikBox - Dependency Setup                      ${NC}"
echo -e "${BOLD}============================================================${NC}"
echo ""

# ── Detect OS ─────────────────────────────────────────────────
DISTRO="$(detect_distro)"
FAMILY="$(detect_family "$DISTRO")"

info "Detected distro: ${BOLD}$DISTRO${NC} (family: $FAMILY)"
echo ""

if [[ "$FAMILY" == "unknown" ]]; then
    err "Unsupported distro: $DISTRO"
    err "Supported: Termux (Android), Arch, Manjaro, Debian, Ubuntu and derivatives"
    exit 1
fi

# ── Check root / sudo ─────────────────────────────────────────
if [[ "$IS_ANDROID" == true ]]; then
    SUDO=""
    info "Termux detected — no sudo needed"
elif [[ "$EUID" -eq 0 ]]; then
    SUDO=""
    warn "Running as root"
else
    if ! command -v sudo &>/dev/null; then
        err "sudo not found. Please run as root or install sudo."
        exit 1
    fi
    SUDO="sudo"
    info "Will use sudo for package installation"
fi

echo ""

# ── Install packages ──────────────────────────────────────────
install_termux() {
    info "Updating Termux packages..."
    pkg update -y

    info "Installing dependencies..."
    pkg install -y         openjdk-17         python         wget         curl         sed         gawk         findutils         coreutils

    ok "Termux packages installed"
}

install_arch() {
    info "Updating package database..."
    $SUDO pacman -Sy --noconfirm

    info "Installing dependencies..."
    $SUDO pacman -S --noconfirm --needed \
        jdk21-openjdk \
        python \
        wget \
        curl \
        sed \
        gawk \
        findutils \
        coreutils

    ok "Arch packages installed"
}

install_debian() {
    info "Updating package lists..."
    $SUDO apt-get update -y

    info "Installing dependencies..."
    $SUDO apt-get install -y \
        default-jdk \
        python3 \
        wget \
        curl \
        sed \
        gawk \
        findutils \
        coreutils

    ok "Debian/Ubuntu packages installed"
}

case "$FAMILY" in
    termux) install_termux ;;
    arch)   install_arch ;;
    debian) install_debian ;;
esac

# ── Verify Java ───────────────────────────────────────────────
echo ""
info "Verifying Java installation..."
if java -version &>/dev/null; then
    JAVA_VER=$(java -version 2>&1 | head -1)
    ok "Java found: $JAVA_VER"
else
    err "Java not found after installation! Check your package manager."
    exit 1
fi

# ── Verify Python ─────────────────────────────────────────────
info "Verifying Python installation..."
if python3 --version &>/dev/null; then
    ok "Python found: $(python3 --version)"
else
    err "Python3 not found after installation!"
    exit 1
fi

# ── Make cos_toolbox.sh executable ───────────────────────────
echo ""
if [[ -f "$SCRIPT_DIR/cos_toolbox.sh" ]]; then
    chmod +x "$SCRIPT_DIR/cos_toolbox.sh"
    ok "cos_toolbox.sh is now executable"
else
    warn "cos_toolbox.sh not found in $SCRIPT_DIR"
fi

# ── Done ──────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}============================================================${NC}"
echo -e "${GREEN}${BOLD}  ✓ Setup complete!${NC}"
echo -e "${BOLD}============================================================${NC}"
echo ""
echo "  Tools dir : $TOOLS_DIR"
echo "  APKEditor : $APKEDITOR_JAR"
echo ""
echo "  Run the porter with:"
echo -e "    ${CYAN}bash cos_toolbox.sh${NC}"
echo ""
