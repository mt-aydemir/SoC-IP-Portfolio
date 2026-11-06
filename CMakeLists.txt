#=============================================================================
# SoC IP Portfolio - Root Build Script
#
# Vendor-independent SystemVerilog IP library.
#
# Usage:
#   cmake -S . -B build -G Ninja
#   cmake --build build --target lint-all
#   ctest --test-dir build --output-on-failure
#
# Copyright (c) 2026 SoC IP Portfolio Contributors
# SPDX-License-Identifier: Apache-2.0
#=============================================================================
cmake_minimum_required(VERSION 3.22)

project(soc_ip_portfolio
  VERSION     0.1.0
  DESCRIPTION "Vendor-independent SystemVerilog SoC IP portfolio"
  LANGUAGES   NONE)

#-----------------------------------------------------------------------------
# Out-of-source build enforcement.
#
# Every generated artifact must live under the binary directory. Refuse to
# configure if the user points the binary directory at the source tree.
#-----------------------------------------------------------------------------
get_filename_component(_src_real "${CMAKE_SOURCE_DIR}" REALPATH)
get_filename_component(_bin_real "${CMAKE_BINARY_DIR}" REALPATH)
if(_src_real STREQUAL _bin_real)
  message(FATAL_ERROR
    "In-source builds are not permitted.\n"
    "Configure with:  cmake -S . -B build -G Ninja")
endif()
unset(_src_real)
unset(_bin_real)

list(APPEND CMAKE_MODULE_PATH "${CMAKE_SOURCE_DIR}/cmake")

#-----------------------------------------------------------------------------
# Options
#-----------------------------------------------------------------------------
option(SOC_IP_ENABLE_LINT   "Register Verilator lint tests"          ON)
option(SOC_IP_ENABLE_SIM    "Register cocotb simulation tests"       ON)
option(SOC_IP_ENABLE_SYNTH  "Register Yosys synthesis tests"         ON)
option(SOC_IP_ENABLE_STA    "Register OpenSTA timing tests"          ON)
option(SOC_IP_ENABLE_FORMAL "Register SymbiYosys formal tests"       ON)
option(SOC_IP_ENABLE_UVM    "Register UVM testbench tests"           ON)
option(SOC_IP_ENABLE_DOCS   "Register Sphinx documentation target"   ON)
option(SOC_IP_WAVES         "Generate waveforms during simulation"   ON)

set(SOC_IP_SIM_TIMEOUT 600 CACHE STRING "Per-simulation CTest timeout (s)")
# Synthesis of the multiplier-heavy blocks is slow on the WebAssembly build of
# Yosys (yowasp-yosys) that a --no-root setup installs, and slower still when
# ctest runs several in parallel. A native Yosys finishes them in seconds.
set(SOC_IP_SYNTH_TIMEOUT 900 CACHE STRING "Per-synthesis CTest timeout (s)")
set(SOC_IP_FORMAL_TIMEOUT 1200 CACHE STRING "Per-proof CTest timeout (s)")
set(SOC_IP_UVM_TIMEOUT 1800 CACHE STRING "Per-UVM-build and per-UVM-test CTest timeout (s)")

#-----------------------------------------------------------------------------
# Canonical output layout. Nothing is ever written into the source tree.
#-----------------------------------------------------------------------------
set(SOC_IP_BUILD_ROOT "${CMAKE_BINARY_DIR}"           CACHE INTERNAL "")
set(SOC_IP_IP_OUT     "${CMAKE_BINARY_DIR}/ip"        CACHE INTERNAL "")
set(SOC_IP_WAVE_OUT   "${CMAKE_BINARY_DIR}/waves"     CACHE INTERNAL "")
set(SOC_IP_REPORT_OUT "${CMAKE_BINARY_DIR}/reports"   CACHE INTERNAL "")
set(SOC_IP_DOC_OUT    "${CMAKE_BINARY_DIR}/docs"      CACHE INTERNAL "")

file(MAKE_DIRECTORY
  "${SOC_IP_IP_OUT}" "${SOC_IP_WAVE_OUT}"
  "${SOC_IP_REPORT_OUT}" "${SOC_IP_DOC_OUT}")

include(SocIpToolchain)
include(SocIpAddIp)

enable_testing()

#-----------------------------------------------------------------------------
# Aggregate targets. Per-IP targets attach themselves to these.
#-----------------------------------------------------------------------------
add_custom_target(lint-all  COMMENT "Lint every IP with Verilator")
add_custom_target(sim-all   COMMENT "Simulate every IP with cocotb")
add_custom_target(synth-all COMMENT "Synthesise every IP with Yosys")
add_custom_target(sta-all   COMMENT "Run OpenSTA on every applicable IP")
add_custom_target(formal-all COMMENT "Prove every IP that has formal properties")
add_custom_target(uvm-all    COMMENT "Build every UVM testbench")

#-----------------------------------------------------------------------------
# IP subdirectories.
#
# Order matters: an IP may only DEPENDS on an IP registered before it.
# The sequence below runs from leaf primitives to full subsystems.
#-----------------------------------------------------------------------------
set(SOC_IP_CATEGORIES cdc clocking memory arithmetic bus dsp ml crypto peripherals soc)

foreach(_category IN LISTS SOC_IP_CATEGORIES)
  if(EXISTS "${CMAKE_SOURCE_DIR}/ip/${_category}/CMakeLists.txt")
    add_subdirectory("ip/${_category}")
  endif()
endforeach()

add_subdirectory(examples)
add_subdirectory(tests)

if(SOC_IP_ENABLE_DOCS)
  add_subdirectory(docs)
endif()

#-----------------------------------------------------------------------------
# `clean` beyond the built-in: wipe generated artefacts but keep the cache.
#-----------------------------------------------------------------------------
add_custom_target(clean-artifacts
  COMMAND ${CMAKE_COMMAND} -E rm -rf
          "${SOC_IP_IP_OUT}" "${SOC_IP_WAVE_OUT}"
          "${SOC_IP_REPORT_OUT}" "${SOC_IP_DOC_OUT}"
  COMMENT "Removing generated IP, wave, report and doc artefacts")

#-----------------------------------------------------------------------------
# Configuration summary
#-----------------------------------------------------------------------------
get_property(_ip_all GLOBAL PROPERTY SOC_IP_REGISTRY)
list(LENGTH _ip_all _ip_count)
message(STATUS "")
message(STATUS "soc-ip-portfolio ${PROJECT_VERSION}")
message(STATUS "  IPs registered : ${_ip_count}")
message(STATUS "  Verilator      : ${SOC_IP_VERILATOR_STATUS}")
message(STATUS "  Yosys          : ${SOC_IP_YOSYS_STATUS}")
message(STATUS "  OpenSTA        : ${SOC_IP_STA_STATUS}")
message(STATUS "  Formal         : ${SOC_IP_FORMAL_STATUS}")
message(STATUS "  UVM            : ${SOC_IP_UVM_STATUS}")
message(STATUS "  cocotb python  : ${SOC_IP_PYTHON_STATUS}")
message(STATUS "  Sphinx         : ${SOC_IP_SPHINX_STATUS}")
message(STATUS "  Build root     : ${CMAKE_BINARY_DIR}")
message(STATUS "")
