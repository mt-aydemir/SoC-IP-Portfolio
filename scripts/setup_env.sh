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
#     ./scripts/setup_env.sh --uvm        # also build Verilator for UVM
#     ./scripts/setup_env.sh --no-verible # skip the Verible lint binaries
#
# --uvm adds the UVM stage's toolchain, which no distribution packages: a
# Verilator new enough for UVM (5.052 or later) built from source into
# ~/tools/verilator-<version> beside the flow's own, with Flex, Bison and
# help2man built into ~/tools/local when the system lacks them, and the UVM
# 2020-3.2 kit that Verilator ships in its test suite copied to
# ~/tools/uvm-2020.3.2. No root is needed. The build compiles for a while
# and wants about 2 GB of memory.
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
DO_UVM=0
DO_VERIBLE=1
# Verible publishes static Linux binaries; the release and its checksum are pinned.
VERIBLE_TAG="${VERIBLE_TAG:-v0.0-4298-g085eef05}"
VERIBLE_SHA256="${VERIBLE_SHA256:-ca83778c7c2b73272277bd670d1851c8caf973fd3283688aeb0d36d4b3598a90}"
UVM_VERILATOR_VERSION="${UVM_VERILATOR_VERSION:-5.054}"
TOOLS="${SOC_IP_TOOLS:-$HOME/tools}"

for arg in "$@"; do
  case "$arg" in
    --apt-only) DO_VENV=0; DO_STA=0 ;;
    --no-sudo)  DO_APT=0 ;;
    --no-sta)   DO_STA=0 ;;
    --no-venv)  DO_VENV=0 ;;
    --no-root)  DO_APT=0; DO_PIP_EDA=1 ;;
    --uvm)      DO_UVM=1 ;;
    --no-verible) DO_VERIBLE=0 ;;
    -h|--help)  sed -n '2,30p' "$0"; exit 0 ;;
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
    "myst-parser[linkify]" \
    sphinxcontrib-wavedrom \
    numpy \
    pyyaml \
    z3-solver
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
  # Yosys is pinned: the flow is verified against this release, and a newer one
  # can change synthesis results between machines.
  "$VENV/bin/python" -m pip install --quiet cmake ninja \
    yowasp-yosys==0.67.0.0.post1190

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
    *) warn "add \$HOME/.local/bin to your PATH to pick up cmake, ninja and yosys"
       # The OpenSTA build below needs this CMake and Ninja.
       export PATH="$HOME/.local/bin:$PATH" ;;
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
    STA_PRIVATE_TCL=0
    if ! command -v swig >/dev/null 2>&1 || [ ! -e /usr/include/tcl8.6/tcl.h ]; then
      say "Unpacking Tcl, SWIG, Bison and Flex into $STA_SYSROOT (no root)"
      STA_PRIVATE_TCL=1
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

    # Eigen, header-only, which OpenSTA's CMake requires. A machine can have
    # Tcl and SWIG and still lack it, so it is checked on its own.
    if [ ! -f /usr/share/eigen3/cmake/Eigen3Config.cmake ]; then
      say "Unpacking Eigen into $STA_SYSROOT (no root)"
      mkdir -p "$STA_SYSROOT/debs"
      ( cd "$STA_SYSROOT/debs" && apt-get download libeigen3-dev )
      dpkg-deb -x "$STA_SYSROOT"/debs/libeigen3-dev_*.deb "$STA_SYSROOT"
      STA_CMAKE_ARGS+=(-DEigen3_DIR="$STA_SYSROOT/usr/share/eigen3/cmake")
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

    if [ "$STA_PRIVATE_TCL" = 1 ]; then
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
# 3a. Verible, the language and style linter (static binaries, no root)
#-----------------------------------------------------------------------------
if [ "$DO_VERIBLE" = 1 ]; then
  VERIBLE_DIR="$TOOLS/verible-$VERIBLE_TAG"
  if [ -x "$VERIBLE_DIR/bin/verible-verilog-lint" ]; then
    say "Verible $VERIBLE_TAG already installed: $VERIBLE_DIR"
  else
    say "Installing Verible $VERIBLE_TAG into $VERIBLE_DIR"
    VERIBLE_TGZ="verible-$VERIBLE_TAG-linux-static-x86_64.tar.gz"
    mkdir -p "$TOOLS/src" "$VERIBLE_DIR"
    curl -fsSL -o "$TOOLS/src/$VERIBLE_TGZ" \
      "https://github.com/chipsalliance/verible/releases/download/$VERIBLE_TAG/$VERIBLE_TGZ"
    echo "$VERIBLE_SHA256  $TOOLS/src/$VERIBLE_TGZ" | sha256sum -c --quiet -
    tar xzf "$TOOLS/src/$VERIBLE_TGZ" -C "$VERIBLE_DIR" --strip-components=1
  fi
fi

#-----------------------------------------------------------------------------
# 3b. Verilator for UVM, and the UVM kit (--uvm)
#-----------------------------------------------------------------------------
if [ "$DO_UVM" = 1 ]; then
  VUVM="$TOOLS/verilator-$UVM_VERILATOR_VERSION"
  UVM_HOME="$TOOLS/uvm-2020.3.2"
  SRC="$TOOLS/src"
  LOCAL="$TOOLS/local"
  mkdir -p "$SRC" "$LOCAL"
  export PATH="$LOCAL/bin:$PATH"

  # Verilator's build needs Flex (with FlexLexer.h), Bison and help2man.
  gnu_tool() {   # name version url
    if ! command -v "$1" >/dev/null 2>&1; then
      say "Building $1 $2 into $LOCAL"
      (cd "$SRC" && curl -fsSLO "$3" && tar xf "$(basename "$3")" \
         && cd "$1-$2" && ./configure --prefix="$LOCAL" >/dev/null \
         && make -j"$JOBS" >/dev/null && make install >/dev/null)
    fi
  }
  gnu_tool bison 3.8.2 https://ftp.gnu.org/gnu/bison/bison-3.8.2.tar.xz
  if ! command -v flex >/dev/null 2>&1 || [ ! -f /usr/include/FlexLexer.h ] \
       && [ ! -f "$LOCAL/include/FlexLexer.h" ]; then
    say "Building flex 2.6.4 into $LOCAL"
    (cd "$SRC" && curl -fsSLO https://github.com/westes/flex/releases/download/v2.6.4/flex-2.6.4.tar.gz \
       && tar xf flex-2.6.4.tar.gz && cd flex-2.6.4 \
       && ./configure --prefix="$LOCAL" >/dev/null && make -j"$JOBS" >/dev/null \
       && make install >/dev/null)
  fi
  gnu_tool help2man 1.49.3 https://ftp.gnu.org/gnu/help2man/help2man-1.49.3.tar.xz

  if [ -x "$VUVM/bin/verilator" ]; then
    say "Verilator $UVM_VERILATOR_VERSION already installed: $VUVM"
  else
    say "Building Verilator $UVM_VERILATOR_VERSION into $VUVM"
    (cd "$SRC" && curl -fsSL -o "verilator-$UVM_VERILATOR_VERSION.tar.gz" \
       "https://github.com/verilator/verilator/archive/refs/tags/v$UVM_VERILATOR_VERSION.tar.gz" \
       && tar xzf "verilator-$UVM_VERILATOR_VERSION.tar.gz" \
       && cd "verilator-$UVM_VERILATOR_VERSION" && autoconf \
       && CPPFLAGS="-I$LOCAL/include" LDFLAGS="-L$LOCAL/lib" ./configure --prefix="$VUVM" >/dev/null \
       && make -j"$((JOBS < 4 ? JOBS : 4))" >/dev/null && make install >/dev/null)
  fi

  # The flattened UVM 2020-3.2 package and its DPI sources (Apache-2.0)
  # ship in Verilator's test suite.
  KIT="$SRC/verilator-$UVM_VERILATOR_VERSION/test_regress/t/uvm"
  if [ ! -f "$UVM_HOME/uvm_pkg_all_v2020_3_2_dpi.svh" ]; then
    say "Staging UVM 2020-3.2 into $UVM_HOME"
    mkdir -p "$UVM_HOME"
    cp "$KIT/uvm_pkg_all_v2020_3_2_dpi.svh" "$UVM_HOME/"
    cp -r "$KIT/v2020_3_2/dpi" "$UVM_HOME/"
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
for v in "$TOOLS"/verible-*/bin/verible-verilog-lint; do
  [ -x "$v" ] && printf '  %-14s %s\n' "verible" "$("$v" --version | head -1)"
done
for v in "$TOOLS"/verilator-*/bin/verilator; do
  [ -x "$v" ] && printf '  %-14s %s\n' "verilator-uvm" "$("$v" --version | head -1)"
done

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
