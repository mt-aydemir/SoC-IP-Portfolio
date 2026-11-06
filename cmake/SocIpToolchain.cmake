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
# Verilator for UVM, and the UVM kit
#
# UVM needs Verilator 5.052 or later, which Ubuntu does not package; the
# flow's own Verilator may be older. setup_env.sh --uvm builds one into
# ~/tools/verilator-<version> and copies the UVM 2020-3.2 kit that Verilator
# ships in its test suite to ~/tools/uvm-2020.3.2. SOC_IP_UVM_VERILATOR and
# SOC_IP_UVM_HOME override the search. Constrained randomisation needs the
# SMT solver found for the formal stage.
#-----------------------------------------------------------------------------
set(SOC_IP_UVM_MIN_VERILATOR "5.052")
set(_uvm_candidates "")
if(DEFINED ENV{SOC_IP_UVM_VERILATOR})
  list(APPEND _uvm_candidates "$ENV{SOC_IP_UVM_VERILATOR}")
endif()
file(GLOB _uvm_globbed "$ENV{HOME}/tools/verilator-*/bin/verilator")
list(SORT _uvm_globbed COMPARE NATURAL ORDER DESCENDING)
list(APPEND _uvm_candidates ${_uvm_globbed})
if(SOC_IP_VERILATOR)
  list(APPEND _uvm_candidates "${SOC_IP_VERILATOR}")
endif()
set(SOC_IP_UVM_VERILATOR "")
foreach(_cand IN LISTS _uvm_candidates)
  if(EXISTS "${_cand}")
    execute_process(COMMAND "${_cand}" --version OUTPUT_VARIABLE _uvm_ver_out
                    ERROR_QUIET OUTPUT_STRIP_TRAILING_WHITESPACE)
    string(REGEX MATCH "[0-9]+\\.[0-9]+" _uvm_ver "${_uvm_ver_out}")
    if(_uvm_ver AND NOT _uvm_ver VERSION_LESS SOC_IP_UVM_MIN_VERILATOR)
      set(SOC_IP_UVM_VERILATOR "${_cand}")
      set(SOC_IP_UVM_VERILATOR_VERSION "${_uvm_ver}")
      break()
    endif()
  endif()
endforeach()
if(DEFINED ENV{SOC_IP_UVM_HOME})
  set(SOC_IP_UVM_HOME "$ENV{SOC_IP_UVM_HOME}")
else()
  set(SOC_IP_UVM_HOME "$ENV{HOME}/tools/uvm-2020.3.2")
endif()
set(SOC_IP_UVM_STATUS "not found (needs Verilator >= ${SOC_IP_UVM_MIN_VERILATOR}; setup_env.sh --uvm)")
if(SOC_IP_UVM_VERILATOR AND EXISTS "${SOC_IP_UVM_HOME}/uvm_pkg_all_v2020_3_2_dpi.svh"
   AND SOC_IP_SMT_SOLVER)
  set(SOC_IP_UVM_STATUS
      "Verilator ${SOC_IP_UVM_VERILATOR_VERSION} + UVM 2020-3.2 (${SOC_IP_UVM_HOME})")
else()
  set(SOC_IP_UVM_VERILATOR "")
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
set(SOC_IP_RUN_UVM    "${SOC_IP_SCRIPT_DIR}/run_uvm.py"        CACHE INTERNAL "")
