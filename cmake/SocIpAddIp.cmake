#=============================================================================
# SocIpAddIp.cmake
#
# Defines add_ip(), the single entry point every IP uses to register itself
# with the build. One call wires up the complete flow:
#
#   lint  (Verilator)  ->  sim (cocotb)  ->  synth (Yosys)  ->  sta (OpenSTA)
#
# The ordering is enforced through CTest fixtures, so `ctest` alone reproduces
# the mandated flow: lint runs before simulation, synthesis only after the
# simulation passes, and timing analysis only after synthesis.
#
# Copyright (c) 2026 SoC IP Portfolio Contributors
# SPDX-License-Identifier: Apache-2.0
#=============================================================================
include_guard(GLOBAL)

define_property(GLOBAL PROPERTY SOC_IP_REGISTRY
  BRIEF_DOCS "Names of all registered IPs"
  FULL_DOCS  "Populated by add_ip(); consumed by the docs and report targets")

#-----------------------------------------------------------------------------
# _soc_ip_flatten_deps(<out_var> <ip> ...)
#
# Depth-first expansion of the dependency graph into a de-duplicated,
# compile-ordered source list (dependencies first).
#-----------------------------------------------------------------------------
function(_soc_ip_flatten_deps out_var)
  set(_acc "")
  foreach(_dep IN LISTS ARGN)
    get_property(_known GLOBAL PROPERTY SOC_IP_REGISTRY)
    if(NOT _dep IN_LIST _known)
      message(FATAL_ERROR
        "IP dependency '${_dep}' is not registered yet.\n"
        "Check the category order in the root CMakeLists.txt: an IP may only "
        "depend on an IP added before it.")
    endif()
    get_property(_dep_srcs GLOBAL PROPERTY SOC_IP_${_dep}_ALLSOURCES)
    list(APPEND _acc ${_dep_srcs})
  endforeach()
  list(REMOVE_DUPLICATES _acc)
  set(${out_var} "${_acc}" PARENT_SCOPE)
endfunction()

#-----------------------------------------------------------------------------
# add_ip(NAME <name> ...)
#
# Options:
#   NO_LINT NO_SIM NO_SYNTH NO_STA   - opt out of a flow stage
#
# Single-value:
#   NAME            IP name, also the CTest suffix                  (required)
#   TOP             top RTL module name                       (default: NAME)
#   CATEGORY        IP family                    (default: parent dir name)
#   CLOCK_PERIOD_NS target clock period for STA               (default: 10.0)
#   CLOCK_PORT      name of the STA clock port                (default: clk)
#   TIMESCALE       Verilator timescale                 (default: 1ns/1ps)
#   SVTB            self-checking SystemVerilog testbench source, relative to
#                   the IP directory; compiled with `verilator --binary`
#   SVTB_TOP        testbench top module          (default: SVTB file stem)
#
# Multi-value:
#   SOURCES         RTL files, relative to the IP directory         (required)
#   DEPENDS         other IP names whose RTL must be compiled in
#   COCOTB_MODULES  python test modules living in <ip>/cocotb
#   PARAMS          NAME=VALUE elaboration parameters for sim/synth/sta
#   LINT_ARGS       extra Verilator arguments
#   SYNTH_ARGS      extra arguments forwarded to run_synth.py
#-----------------------------------------------------------------------------
function(add_ip)
  set(_opts    NO_LINT NO_SIM NO_SYNTH NO_STA)
  set(_one     NAME TOP CATEGORY CLOCK_PERIOD_NS CLOCK_PORT TIMESCALE SVTB SVTB_TOP)
  set(_multi   SOURCES DEPENDS COCOTB_MODULES PARAMS LINT_ARGS SYNTH_ARGS)
  cmake_parse_arguments(IP "${_opts}" "${_one}" "${_multi}" ${ARGN})

  if(NOT IP_NAME)
    message(FATAL_ERROR "add_ip(): NAME is required")
  endif()
  if(NOT IP_SOURCES)
    message(FATAL_ERROR "add_ip(${IP_NAME}): SOURCES is required")
  endif()
  if(IP_UNPARSED_ARGUMENTS)
    message(FATAL_ERROR "add_ip(${IP_NAME}): unknown arguments: ${IP_UNPARSED_ARGUMENTS}")
  endif()

  if(NOT IP_TOP)
    set(IP_TOP "${IP_NAME}")
  endif()
  if(NOT IP_CATEGORY)
    get_filename_component(IP_CATEGORY "${CMAKE_CURRENT_SOURCE_DIR}" DIRECTORY)
    get_filename_component(IP_CATEGORY "${IP_CATEGORY}" NAME)
  endif()
  if(NOT IP_CLOCK_PERIOD_NS)
    set(IP_CLOCK_PERIOD_NS 10.0)
  endif()
  if(NOT IP_CLOCK_PORT)
    set(IP_CLOCK_PORT clk)
  endif()
  if(NOT IP_TIMESCALE)
    set(IP_TIMESCALE "1ns/1ps")
  endif()

  # --- absolute source paths ------------------------------------------------
  set(_own_srcs "")
  foreach(_s IN LISTS IP_SOURCES)
    if(IS_ABSOLUTE "${_s}")
      set(_abs "${_s}")
    else()
      set(_abs "${CMAKE_CURRENT_SOURCE_DIR}/${_s}")
    endif()
    if(NOT EXISTS "${_abs}")
      message(FATAL_ERROR "add_ip(${IP_NAME}): missing source ${_abs}")
    endif()
    list(APPEND _own_srcs "${_abs}")
  endforeach()

  _soc_ip_flatten_deps(_dep_srcs ${IP_DEPENDS})
  set(_all_srcs ${_dep_srcs} ${_own_srcs})
  list(REMOVE_DUPLICATES _all_srcs)

  # --- register -------------------------------------------------------------
  set_property(GLOBAL APPEND PROPERTY SOC_IP_REGISTRY "${IP_NAME}")
  set_property(GLOBAL PROPERTY SOC_IP_${IP_NAME}_ALLSOURCES "${_all_srcs}")
  set_property(GLOBAL PROPERTY SOC_IP_${IP_NAME}_OWNSOURCES "${_own_srcs}")
  set_property(GLOBAL PROPERTY SOC_IP_${IP_NAME}_TOP        "${IP_TOP}")
  set_property(GLOBAL PROPERTY SOC_IP_${IP_NAME}_CATEGORY   "${IP_CATEGORY}")
  set_property(GLOBAL PROPERTY SOC_IP_${IP_NAME}_DIR        "${CMAKE_CURRENT_SOURCE_DIR}")

  set(_out "${SOC_IP_IP_OUT}/${IP_CATEGORY}/${IP_NAME}")
  file(MAKE_DIRECTORY "${_out}")

  # PARAMS arrive as a CMake list; forward as repeated --param NAME=VALUE.
  set(_param_args "")
  foreach(_p IN LISTS IP_PARAMS)
    list(APPEND _param_args --param "${_p}")
  endforeach()

  #---------------------------------------------------------------------------
  # Stage 1: Verilator lint
  #---------------------------------------------------------------------------
  if(SOC_IP_ENABLE_LINT AND SOC_IP_VERILATOR AND NOT IP_NO_LINT)
    set(_lint_cmd
      "${SOC_IP_PYTHON}" "${SOC_IP_RUN_LINT}"
        --verilator "${SOC_IP_VERILATOR}"
        --top       "${IP_TOP}"
        --name      "${IP_NAME}"
        --out-dir   "${_out}/lint"
        --report    "${SOC_IP_REPORT_OUT}/lint/${IP_NAME}.log"
        --timescale "${IP_TIMESCALE}"
        ${_param_args})
    # Joined form, not separate arguments: a lint flag such as
    # -Wno-MULTIDRIVEN starts with a dash, and argparse would treat it as an
    # option of run_lint.py rather than as the value of --extra-arg.
    foreach(_a IN LISTS IP_LINT_ARGS)
      list(APPEND _lint_cmd "--extra-arg=${_a}")
    endforeach()
    list(APPEND _lint_cmd --sources ${_all_srcs})

    add_custom_target(lint_${IP_NAME}
      COMMAND ${_lint_cmd}
      WORKING_DIRECTORY "${CMAKE_BINARY_DIR}"
      COMMENT "[lint ] ${IP_CATEGORY}/${IP_NAME}"
      VERBATIM)
    add_dependencies(lint-all lint_${IP_NAME})

    add_test(NAME lint.${IP_CATEGORY}.${IP_NAME}
             COMMAND ${_lint_cmd}
             WORKING_DIRECTORY "${CMAKE_BINARY_DIR}")
    set_tests_properties(lint.${IP_CATEGORY}.${IP_NAME} PROPERTIES
      LABELS "lint;${IP_CATEGORY}"
      TIMEOUT 120
      FIXTURES_SETUP F_lint_${IP_NAME})
  endif()

  #---------------------------------------------------------------------------
  # Stage 2: cocotb simulation (Verilator back end)
  #---------------------------------------------------------------------------
  if(SOC_IP_ENABLE_SIM AND SOC_IP_HAVE_COCOTB AND SOC_IP_VERILATOR
     AND IP_COCOTB_MODULES AND NOT IP_NO_SIM)
    if(SOC_IP_WAVES)
      set(_waves --waves)
    else()
      set(_waves "")
    endif()
    foreach(_mod IN LISTS IP_COCOTB_MODULES)
      set(_sim_cmd
        "${SOC_IP_PYTHON}" "${SOC_IP_RUN_COCOTB}"
          --top        "${IP_TOP}"
          --name       "${IP_NAME}"
          --module     "${_mod}"
          --test-dir   "${CMAKE_CURRENT_SOURCE_DIR}/cocotb"
          --build-dir  "${_out}/sim/${_mod}"
          --wave-dir   "${SOC_IP_WAVE_OUT}/${IP_NAME}"
          --results    "${SOC_IP_REPORT_OUT}/sim/${IP_NAME}.${_mod}.xml"
          --timescale  "${IP_TIMESCALE}"
          --verilator  "${SOC_IP_VERILATOR}"
          ${_waves} ${_param_args}
          --sources    ${_all_srcs})

      add_custom_target(sim_${IP_NAME}_${_mod}
        COMMAND ${_sim_cmd}
        WORKING_DIRECTORY "${CMAKE_BINARY_DIR}"
        COMMENT "[sim  ] ${IP_CATEGORY}/${IP_NAME}:${_mod}"
        VERBATIM)
      add_dependencies(sim-all sim_${IP_NAME}_${_mod})

      add_test(NAME sim.${IP_CATEGORY}.${IP_NAME}.${_mod}
               COMMAND ${_sim_cmd}
               WORKING_DIRECTORY "${CMAKE_BINARY_DIR}")
      set_tests_properties(sim.${IP_CATEGORY}.${IP_NAME}.${_mod} PROPERTIES
        LABELS "sim;${IP_CATEGORY}"
        TIMEOUT ${SOC_IP_SIM_TIMEOUT}
        FIXTURES_REQUIRED F_lint_${IP_NAME}
        FIXTURES_SETUP    F_sim_${IP_NAME})
    endforeach()
  endif()

  #---------------------------------------------------------------------------
  # Stage 2b: self-checking SystemVerilog testbench (verilator --binary)
  #
  # The Python-free path. It proves the IP is usable on a plain SystemVerilog
  # simulator and gives a fast signal during development, independently of
  # cocotb. Runs in parallel with the cocotb suite; both gate synthesis.
  #---------------------------------------------------------------------------
  if(SOC_IP_ENABLE_SIM AND SOC_IP_VERILATOR AND IP_SVTB AND NOT IP_NO_SIM)
    if(IS_ABSOLUTE "${IP_SVTB}")
      set(_tb_src "${IP_SVTB}")
    else()
      set(_tb_src "${CMAKE_CURRENT_SOURCE_DIR}/${IP_SVTB}")
    endif()
    if(NOT EXISTS "${_tb_src}")
      message(FATAL_ERROR "add_ip(${IP_NAME}): missing SVTB source ${_tb_src}")
    endif()

    # The testbench instantiates the DUT with its own localparams, so the
    # elaboration overrides that apply to the DUT are deliberately not passed
    # here: -G would target the testbench top, which has no such parameters.
    if(NOT IP_SVTB_TOP)
      get_filename_component(IP_SVTB_TOP "${_tb_src}" NAME_WE)
    endif()

    if(SOC_IP_WAVES)
      set(_svtb_waves --waves --wave-dir "${SOC_IP_WAVE_OUT}/${IP_NAME}")
    else()
      set(_svtb_waves "")
    endif()

    set(_svtb_cmd
      "${SOC_IP_PYTHON}" "${SOC_IP_RUN_SVTB}"
        --verilator "${SOC_IP_VERILATOR}"
        --top       "${IP_SVTB_TOP}"
        --name      "${IP_NAME}"
        --out-dir   "${_out}/svtb"
        --report    "${SOC_IP_REPORT_OUT}/svtb/${IP_NAME}.log"
        --timescale "${IP_TIMESCALE}"
        ${_svtb_waves}
        --sources   ${_all_srcs} "${_tb_src}")

    add_custom_target(svtb_${IP_NAME}
      COMMAND ${_svtb_cmd}
      WORKING_DIRECTORY "${CMAKE_BINARY_DIR}"
      COMMENT "[svtb ] ${IP_CATEGORY}/${IP_NAME}"
      VERBATIM)
    add_dependencies(sim-all svtb_${IP_NAME})

    add_test(NAME svtb.${IP_CATEGORY}.${IP_NAME}
             COMMAND ${_svtb_cmd}
             WORKING_DIRECTORY "${CMAKE_BINARY_DIR}")
    set_tests_properties(svtb.${IP_CATEGORY}.${IP_NAME} PROPERTIES
      LABELS "svtb;sim;${IP_CATEGORY}"
      TIMEOUT ${SOC_IP_SIM_TIMEOUT}
      FIXTURES_REQUIRED F_lint_${IP_NAME}
      FIXTURES_SETUP    F_sim_${IP_NAME})
  endif()

  #---------------------------------------------------------------------------
  # Stage 3: Yosys synthesis (generic technology mapping, no vendor cells)
  #---------------------------------------------------------------------------
  if(SOC_IP_ENABLE_SYNTH AND SOC_IP_YOSYS AND NOT IP_NO_SYNTH)
    set(_synth_cmd
      "${SOC_IP_PYTHON}" "${SOC_IP_RUN_SYNTH}"
        --yosys    "${SOC_IP_YOSYS}"
        --top      "${IP_TOP}"
        --name     "${IP_NAME}"
        --out-dir  "${_out}/synth"
        --report   "${SOC_IP_REPORT_OUT}/synth/${IP_NAME}.json"
        --liberty  "${CMAKE_SOURCE_DIR}/scripts/lib/generic_stdcell.lib"
        ${IP_SYNTH_ARGS} ${_param_args}
        --sources  ${_all_srcs})

    add_custom_target(synth_${IP_NAME}
      COMMAND ${_synth_cmd}
      WORKING_DIRECTORY "${CMAKE_BINARY_DIR}"
      COMMENT "[synth] ${IP_CATEGORY}/${IP_NAME}"
      VERBATIM)
    add_dependencies(synth-all synth_${IP_NAME})

    add_test(NAME synth.${IP_CATEGORY}.${IP_NAME}
             COMMAND ${_synth_cmd}
             WORKING_DIRECTORY "${CMAKE_BINARY_DIR}")
    set_tests_properties(synth.${IP_CATEGORY}.${IP_NAME} PROPERTIES
      LABELS "synth;${IP_CATEGORY}"
      TIMEOUT ${SOC_IP_SYNTH_TIMEOUT}
      FIXTURES_SETUP F_synth_${IP_NAME})
    if(SOC_IP_ENABLE_SIM AND SOC_IP_HAVE_COCOTB AND IP_COCOTB_MODULES AND NOT IP_NO_SIM)
      set_tests_properties(synth.${IP_CATEGORY}.${IP_NAME} PROPERTIES
        FIXTURES_REQUIRED F_sim_${IP_NAME})
    endif()
  endif()

  #---------------------------------------------------------------------------
  # Stage 4: OpenSTA timing analysis on the synthesised netlist
  #---------------------------------------------------------------------------
  if(SOC_IP_ENABLE_STA AND SOC_IP_STA AND SOC_IP_YOSYS AND NOT IP_NO_STA AND NOT IP_NO_SYNTH)
    set(_sta_cmd
      "${SOC_IP_PYTHON}" "${SOC_IP_RUN_STA}"
        --sta      "${SOC_IP_STA}"
        --top      "${IP_TOP}"
        --name     "${IP_NAME}"
        --netlist  "${_out}/synth/${IP_NAME}.mapped.v"
        --liberty  "${CMAKE_SOURCE_DIR}/scripts/lib/generic_stdcell.lib"
        --period   "${IP_CLOCK_PERIOD_NS}"
        --clock    "${IP_CLOCK_PORT}"
        --out-dir  "${_out}/sta"
        --report   "${SOC_IP_REPORT_OUT}/sta/${IP_NAME}.rpt")

    add_custom_target(sta_${IP_NAME}
      COMMAND ${_sta_cmd}
      WORKING_DIRECTORY "${CMAKE_BINARY_DIR}"
      COMMENT "[sta  ] ${IP_CATEGORY}/${IP_NAME}"
      VERBATIM)
    add_dependencies(sta-all sta_${IP_NAME})
    add_dependencies(sta_${IP_NAME} synth_${IP_NAME})

    add_test(NAME sta.${IP_CATEGORY}.${IP_NAME}
             COMMAND ${_sta_cmd}
             WORKING_DIRECTORY "${CMAKE_BINARY_DIR}")
    set_tests_properties(sta.${IP_CATEGORY}.${IP_NAME} PROPERTIES
      LABELS "sta;${IP_CATEGORY}"
      TIMEOUT 300
      FIXTURES_REQUIRED F_synth_${IP_NAME})
  endif()
endfunction()

#-----------------------------------------------------------------------------
# add_ip_category(<name> <ip_dir> ...)
#
# Convenience wrapper used by ip/<category>/CMakeLists.txt.
#-----------------------------------------------------------------------------
function(add_ip_category category)
  foreach(_ip IN LISTS ARGN)
    if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/${_ip}/CMakeLists.txt")
      add_subdirectory("${_ip}")
    else()
      message(WARNING "ip/${category}/${_ip}: no CMakeLists.txt, skipping")
    endif()
  endforeach()
endfunction()
