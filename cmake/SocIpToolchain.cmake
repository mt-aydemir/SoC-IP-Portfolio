#=============================================================================
# SocIpToolchain.cmake
#
# Locates the external EDA and Python tooling. Nothing here is fatal: a
# missing tool simply disables the corresponding flow so that, for example,
# lint and simulation still work on a machine without OpenSTA.
#
# Copyright (c) 2026 SoC IP Portfolio Contributors
# SPDX-License-Identifier: Apache-2.0
#=============================================================================
include_guard(GLOBAL)

#-----------------------------------------------------------------------------
# Python interpreter.
#
# Prefer, in order:
#   1. -DSOC_IP_PYTHON=<path>
#   2. $SOC_IP_VENV/bin/python
#   3. ~/.venvs/soc-ip-portfolio/bin/python   (created by scripts/setup_env.sh)
#   4. whatever python3 is on PATH
#-----------------------------------------------------------------------------
if(NOT SOC_IP_PYTHON)
  if(DEFINED ENV{SOC_IP_VENV} AND EXISTS "$ENV{SOC_IP_VENV}/bin/python")
    set(SOC_IP_PYTHON "$ENV{SOC_IP_VENV}/bin/python")
  elseif(EXISTS "$ENV{HOME}/.venvs/soc-ip-portfolio/bin/python")
    set(SOC_IP_PYTHON "$ENV{HOME}/.venvs/soc-ip-portfolio/bin/python")
  else()
    find_program(SOC_IP_PYTHON NAMES python3 python)
  endif()
endif()
set(SOC_IP_PYTHON "${SOC_IP_PYTHON}" CACHE FILEPATH "Python interpreter used for cocotb")

set(SOC_IP_PYTHON_STATUS "not found")
set(SOC_IP_HAVE_COCOTB OFF)
if(SOC_IP_PYTHON)
  execute_process(
    COMMAND "${SOC_IP_PYTHON}" -c "import cocotb;print(cocotb.__version__)"
    OUTPUT_VARIABLE _cocotb_ver
    ERROR_QUIET
    RESULT_VARIABLE _cocotb_rc
    OUTPUT_STRIP_TRAILING_WHITESPACE)
  if(_cocotb_rc EQUAL 0)
    set(SOC_IP_HAVE_COCOTB ON)
    set(SOC_IP_PYTHON_STATUS "${SOC_IP_PYTHON} (cocotb ${_cocotb_ver})")
  else()
    set(SOC_IP_PYTHON_STATUS "${SOC_IP_PYTHON} (cocotb MISSING)")
  endif()
endif()

#-----------------------------------------------------------------------------
# Verilator - lint and simulation
#-----------------------------------------------------------------------------
find_program(SOC_IP_VERILATOR NAMES verilator)
set(SOC_IP_VERILATOR_STATUS "not found")
if(SOC_IP_VERILATOR)
  execute_process(
    COMMAND "${SOC_IP_VERILATOR}" --version
    OUTPUT_VARIABLE _vl_ver ERROR_QUIET OUTPUT_STRIP_TRAILING_WHITESPACE)
  set(SOC_IP_VERILATOR_STATUS "${_vl_ver}")
endif()

#-----------------------------------------------------------------------------
# Yosys - synthesis
#-----------------------------------------------------------------------------
find_program(SOC_IP_YOSYS NAMES yosys)
set(SOC_IP_YOSYS_STATUS "not found")
if(SOC_IP_YOSYS)
  execute_process(
    COMMAND "${SOC_IP_YOSYS}" -V
    OUTPUT_VARIABLE _ys_ver ERROR_QUIET OUTPUT_STRIP_TRAILING_WHITESPACE)
  string(REGEX REPLACE "\n.*" "" _ys_ver "${_ys_ver}")
  set(SOC_IP_YOSYS_STATUS "${_ys_ver}")
endif()

#-----------------------------------------------------------------------------
# OpenSTA - static timing analysis
#-----------------------------------------------------------------------------
find_program(SOC_IP_STA NAMES sta opensta)
set(SOC_IP_STA_STATUS "not found")
if(SOC_IP_STA)
  set(SOC_IP_STA_STATUS "${SOC_IP_STA}")
endif()

#-----------------------------------------------------------------------------
# SymbiYosys and an SMT solver - formal verification
#
# The no-root setup has SymbiYosys as yowasp-sby, which ships with
# yowasp-yosys, and Z3 from the z3-solver wheel, which carries a native z3
# binary; both land in the venv. A native sby and any solver smtbmc accepts
# work as well.
#-----------------------------------------------------------------------------
get_filename_component(_py_bin "${SOC_IP_PYTHON}" DIRECTORY)
find_program(SOC_IP_SBY NAMES sby yowasp-sby HINTS "${_py_bin}")
find_program(SOC_IP_SMT_SOLVER NAMES z3 yices-smt2 boolector bitwuzla HINTS "${_py_bin}")
set(SOC_IP_FORMAL_STATUS "not found")
if(SOC_IP_SBY AND SOC_IP_SMT_SOLVER)
  get_filename_component(SOC_IP_SMT_SOLVER_NAME "${SOC_IP_SMT_SOLVER}" NAME)
  string(REGEX REPLACE "-smt2$" "" SOC_IP_SMT_SOLVER_NAME "${SOC_IP_SMT_SOLVER_NAME}")
  set(SOC_IP_FORMAL_STATUS "${SOC_IP_SBY} + ${SOC_IP_SMT_SOLVER_NAME}")
elseif(SOC_IP_SBY)
  set(SOC_IP_FORMAL_STATUS "${SOC_IP_SBY}, no SMT solver")
endif()

#-----------------------------------------------------------------------------
# Sphinx - documentation
#-----------------------------------------------------------------------------
get_filename_component(_py_dir "${SOC_IP_PYTHON}" DIRECTORY)
find_program(SOC_IP_SPHINX NAMES sphinx-build HINTS "${_py_dir}")
set(SOC_IP_SPHINX_STATUS "not found")
if(SOC_IP_SPHINX)
  set(SOC_IP_SPHINX_STATUS "${SOC_IP_SPHINX}")
endif()

#-----------------------------------------------------------------------------
# Shared script locations
#-----------------------------------------------------------------------------
set(SOC_IP_SCRIPT_DIR "${CMAKE_SOURCE_DIR}/scripts"            CACHE INTERNAL "")
set(SOC_IP_VERIF_DIR  "${CMAKE_SOURCE_DIR}/verification"       CACHE INTERNAL "")
set(SOC_IP_RUN_COCOTB "${SOC_IP_SCRIPT_DIR}/run_cocotb.py"     CACHE INTERNAL "")
set(SOC_IP_RUN_LINT   "${SOC_IP_SCRIPT_DIR}/run_lint.py"       CACHE INTERNAL "")
set(SOC_IP_RUN_SVTB   "${SOC_IP_SCRIPT_DIR}/run_svtb.py"       CACHE INTERNAL "")
set(SOC_IP_RUN_SYNTH  "${SOC_IP_SCRIPT_DIR}/run_synth.py"      CACHE INTERNAL "")
set(SOC_IP_RUN_STA    "${SOC_IP_SCRIPT_DIR}/run_sta.py"        CACHE INTERNAL "")
set(SOC_IP_RUN_FORMAL "${SOC_IP_SCRIPT_DIR}/run_formal.py"     CACHE INTERNAL "")
