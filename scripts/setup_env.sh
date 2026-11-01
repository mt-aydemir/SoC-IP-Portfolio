#!/usr/bin/env bash
#=============================================================================
# setup_env.sh - provision the soc-ip-portfolio toolchain on Ubuntu / WSL2.
#
# Run once from inside WSL2:
#
#     ./scripts/setup_env.sh              # everything
#     ./scripts/setup_env.sh --apt-only   # system packages only (needs sudo)
#     ./scripts/setup_env.sh --no-sudo    # venv + OpenSTA only, skip apt
#     ./scripts/setup_env.sh --no-venv    # skip the Python virtual environment
#     ./scripts/setup_env.sh --no-sta     # skip the OpenSTA source build
#     ./scripts/setup_env.sh --no-root    # no sudo anywhere: CMake, Ninja and
#                                         # Yosys from PyPI into the venv
#
# --no-root exists for machines where sudo is not available. It installs
# CMake, Ninja and Yosys from PyPI, and builds OpenSTA against Tcl, SWIG, Bison
# and Flex unpacked from their .deb packages into a private sysroot
# (apt-get download needs no root). Every stage of the flow works.
#
# Idempotent: re-running only installs what is missing.
#
# Copyright (c) 2026 SoC IP Portfolio Contributors
# SPDX-License-Identifier: Apache-2.0
#=============================================================================
set -euo pipefail

VENV="${SOC_IP_VENV:-$HOME/.venvs/soc-ip-portfolio}"
OPENSTA_SRC="${OPENSTA_SRC:-$HOME/.local/src/OpenSTA}"
# OpenSTA publishes no release tags, so the build is pinned to a commit.
# 3.1.0, verified against this flow on 2026-11-01.
OPENSTA_REV="${OPENSTA_REV:-cc365d0914ddd11b61575c4a06cde3ecceeb0d01}"
CUDD_TAG="${CUDD_TAG:-3.0.0}"
# Private sysroot for OpenSTA's build tools when apt is not available.
STA_SYSROOT="${STA_SYSROOT:-$HOME/.local/opt/sta-sysroot}"
JOBS="$(nproc)"

DO_APT=1
DO_VENV=1
DO_STA=1
DO_PIP_EDA=0

for arg in "$@"; do
  case "$arg" in
    --apt-only) DO_VENV=0; DO_STA=0 ;;
    --no-sudo)  DO_APT=0 ;;
    --no-sta)   DO_STA=0 ;;
    --no-venv)  DO_VENV=0 ;;
    --no-root)  DO_APT=0; DO_PIP_EDA=1 ;;
    -h|--help)  sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[warn] %s\033[0m\n' "$*" >&2; }

#-----------------------------------------------------------------------------
# 1. System packages
#-----------------------------------------------------------------------------
APT_PACKAGES=(
  # build essentials
  build-essential git ca-certificates pkg-config
  clang clang-format clang-tidy
  cmake ninja-build
  # python
  python3 python3-pip python3-venv python3-dev
  # RTL toolchain
  verilator yosys
  # OpenSTA build dependencies
  tcl-dev tcl tclsh-dev swig bison flex libeigen3-dev zlib1g-dev
  # waveform viewing
  gtkwave
  # documentation helpers
  graphviz
)

if [ "$DO_APT" = 1 ]; then
  say "Installing system packages (sudo required)"
  sudo apt-get update
  # tclsh-dev does not exist on every release; filter to available packages.
  AVAILABLE=()
  for pkg in "${APT_PACKAGES[@]}"; do
    if apt-cache show "$pkg" >/dev/null 2>&1; then
      AVAILABLE+=("$pkg")
    else
      warn "package not available on this release, skipping: $pkg"
    fi
  done
  sudo apt-get install -y --no-install-recommends "${AVAILABLE[@]}"
fi

#-----------------------------------------------------------------------------
# 2. Python virtual environment (cocotb, pytest, Sphinx)
#-----------------------------------------------------------------------------
if [ "$DO_VENV" = 1 ]; then
  say "Creating Python virtual environment at $VENV"
  mkdir -p "$(dirname "$VENV")"
  [ -d "$VENV" ] || python3 -m venv "$VENV"
  "$VENV/bin/python" -m pip install --upgrade --quiet pip setuptools wheel
  "$VENV/bin/python" -m pip install --quiet \
    "cocotb>=1.9,<2.0" \
    cocotb-bus \
    pytest \
    pytest-xdist \
    sphinx \
    sphinx-rtd-theme \
    myst-parser \
    sphinxcontrib-wavedrom \
    numpy \
    pyyaml
fi

#-----------------------------------------------------------------------------
# 2b. EDA tooling from PyPI, for machines without sudo.
#
# CMake and Ninja are published by Kitware as wheels containing the real
# binaries. Yosys is available as yowasp-yosys, a WebAssembly build maintained
# by YosysHQ: slower than the native package but functionally identical, and it
# needs no system packages at all.
#
# The binaries are symlinked into ~/.local/bin so that CMake's find_program
# locates them the same way it would locate the apt versions.
#-----------------------------------------------------------------------------
if [ "$DO_PIP_EDA" = 1 ]; then
  say "Installing CMake, Ninja and Yosys from PyPI (no sudo required)"
  "$VENV/bin/python" -m pip install --quiet cmake ninja yowasp-yosys

  mkdir -p "$HOME/.local/bin"
  for tool in cmake ctest cpack ninja; do
    if [ -x "$VENV/bin/$tool" ]; then
      ln -sf "$VENV/bin/$tool" "$HOME/.local/bin/$tool"
    fi
  done

  # yowasp-yosys installs under its own name; the flow invokes plain `yosys`.
  if [ -x "$VENV/bin/yowasp-yosys" ]; then
    printf '#!/bin/sh\nexec %s/bin/yowasp-yosys "$@"\n' "$VENV" \
      > "$HOME/.local/bin/yosys"
    chmod +x "$HOME/.local/bin/yosys"
  fi

  case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) warn "add \$HOME/.local/bin to your PATH to pick up cmake, ninja and yosys" ;;
  esac

fi

#-----------------------------------------------------------------------------
# 3. OpenSTA (not packaged for Ubuntu - built from source)
#-----------------------------------------------------------------------------
if [ "$DO_STA" = 1 ]; then
  if command -v sta >/dev/null 2>&1; then
    say "OpenSTA already installed: $(command -v sta)"
  else
    mkdir -p "$(dirname "$OPENSTA_SRC")" "$HOME/.local/bin" "$HOME/.local/libexec"

    # Build tools. With apt they were installed above; without it, unpack the
    # same packages into a private sysroot. apt-get download needs no root.
    STA_CMAKE_ARGS=()
    if ! command -v swig >/dev/null 2>&1 || [ ! -e /usr/include/tcl8.6/tcl.h ]; then
      say "Unpacking Tcl, SWIG, Bison and Flex into $STA_SYSROOT (no root)"
      mkdir -p "$STA_SYSROOT/debs"
      ( cd "$STA_SYSROOT/debs" &&
        apt-get download tcl8.6-dev libtcl8.6 tcl8.6 swig bison flex \
                         libfl-dev libfl2 libbison-dev )
      for deb in "$STA_SYSROOT"/debs/*.deb; do dpkg-deb -x "$deb" "$STA_SYSROOT"; done
      ln -sf tclsh8.6 "$STA_SYSROOT/usr/bin/tclsh"
      export PATH="$STA_SYSROOT/usr/bin:$PATH"
      export SWIG_LIB="$STA_SYSROOT/usr/share/swig4.0"
      export BISON_PKGDATADIR="$STA_SYSROOT/usr/share/bison"
      export LD_LIBRARY_PATH="$STA_SYSROOT/usr/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH:-}"
      export TCL_LIBRARY="$STA_SYSROOT/usr/share/tcltk/tcl8.6"
      STA_CMAKE_ARGS=(
        -DTCL_LIBRARY="$STA_SYSROOT/usr/lib/x86_64-linux-gnu/libtcl8.6.so"
        -DTCL_HEADER="$STA_SYSROOT/usr/include/tcl8.6/tcl.h"
        -DSWIG_EXECUTABLE="$STA_SYSROOT/usr/bin/swig4.0"
        -DBISON_EXECUTABLE="$STA_SYSROOT/usr/bin/bison"
        -DFLEX_EXECUTABLE="$STA_SYSROOT/usr/bin/flex"
        -DFLEX_INCLUDE_DIR="$STA_SYSROOT/usr/include")
    fi

    # CUDD, which OpenSTA links against. Not packaged for Ubuntu.
    if [ ! -f "$HOME/.local/cudd/lib/libcudd.a" ]; then
      say "Building CUDD $CUDD_TAG"
      CUDD_SRC="$(dirname "$OPENSTA_SRC")/cudd"
      [ -d "$CUDD_SRC/.git" ] || git clone https://github.com/cuddorg/cudd.git "$CUDD_SRC"
      ( cd "$CUDD_SRC" && git checkout -q "$CUDD_TAG" &&
        touch aclocal.m4 configure Makefile.am Makefile.in config.h.in &&
        ./configure --prefix="$HOME/.local/cudd" && make -j "$JOBS" && make install )
    fi

    say "Building OpenSTA at ${OPENSTA_REV:0:12}"
    if [ ! -d "$OPENSTA_SRC/.git" ]; then
      git clone https://github.com/parallaxsw/OpenSTA.git "$OPENSTA_SRC"
    fi
    git -C "$OPENSTA_SRC" checkout -q "$OPENSTA_REV"
    cmake -S "$OPENSTA_SRC" -B "$OPENSTA_SRC/build" -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DCUDD_DIR="$HOME/.local/cudd" \
      -DUSE_TCL_READLINE=OFF \
      "${STA_CMAKE_ARGS[@]}"
    cmake --build "$OPENSTA_SRC/build" -j "$JOBS"

    if [ "${#STA_CMAKE_ARGS[@]}" -gt 0 ]; then
      # Built against the private Tcl: install behind a wrapper that finds it.
      cp "$OPENSTA_SRC/build/sta" "$HOME/.local/libexec/sta"
      cat > "$HOME/.local/bin/sta" <<WRAP
#!/usr/bin/env bash
export LD_LIBRARY_PATH=$STA_SYSROOT/usr/lib/x86_64-linux-gnu:\${LD_LIBRARY_PATH:-}
export TCL_LIBRARY=$STA_SYSROOT/usr/share/tcltk/tcl8.6
exec $HOME/.local/libexec/sta "\$@"
WRAP
      chmod +x "$HOME/.local/bin/sta"
    else
      cp "$OPENSTA_SRC/build/sta" "$HOME/.local/bin/sta"
    fi

    case ":$PATH:" in
      *":$HOME/.local/bin:"*) ;;
      *) warn "add \$HOME/.local/bin to your PATH to pick up 'sta'" ;;
    esac
  fi
fi

#-----------------------------------------------------------------------------
# 4. Verification
#-----------------------------------------------------------------------------
say "Toolchain summary"
check() {
  printf '  %-14s ' "$1"
  if command -v "$1" >/dev/null 2>&1; then
    "$1" ${2:---version} 2>&1 | head -1
  else
    printf '\033[1;31mMISSING\033[0m\n'
  fi
}
check git
check gcc
check clang
check cmake
check ninja
check verilator
check yosys -V
check gtkwave
check sta -version

if [ -x "$VENV/bin/python" ]; then
  printf '  %-14s ' "python"
  "$VENV/bin/python" --version 2>&1 | head -1
  printf '  %-14s ' "cocotb"
  "$VENV/bin/python" -c 'import cocotb; print(cocotb.__version__)' 2>&1 | head -1
  printf '  %-14s ' "sphinx"
  "$VENV/bin/sphinx-build" --version 2>&1 | head -1
else
  printf '  %-14s \033[1;33m%s\033[0m\n' "venv" "not created ($VENV)"
fi

cat <<EOF

Environment ready.

  export SOC_IP_VENV="$VENV"
  cmake -S . -B build -G Ninja
  cmake --build build --target lint-all
  ctest --test-dir build --output-on-failure

EOF
