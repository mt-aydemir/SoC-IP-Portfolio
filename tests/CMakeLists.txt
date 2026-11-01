#=============================================================================
# tests/ - repository-level tests
#
# These check the infrastructure itself (naming rules, required files, style)
# rather than any single IP. Per-IP functional tests are registered by
# add_ip() and live next to the IP.
#=============================================================================

if(SOC_IP_PYTHON)
  add_test(NAME repo.structure
    COMMAND "${SOC_IP_PYTHON}" "${CMAKE_CURRENT_SOURCE_DIR}/test_repo_structure.py"
            --root "${CMAKE_SOURCE_DIR}")
  set_tests_properties(repo.structure PROPERTIES LABELS "repo" TIMEOUT 120)

  add_test(NAME repo.rtl_style
    COMMAND "${SOC_IP_PYTHON}" "${CMAKE_CURRENT_SOURCE_DIR}/test_rtl_style.py"
            --root "${CMAKE_SOURCE_DIR}")
  set_tests_properties(repo.rtl_style PROPERTIES LABELS "repo" TIMEOUT 120)

  add_test(NAME repo.no_source_pollution
    COMMAND "${SOC_IP_PYTHON}" "${CMAKE_CURRENT_SOURCE_DIR}/test_no_source_pollution.py"
            --root "${CMAKE_SOURCE_DIR}")
  set_tests_properties(repo.no_source_pollution PROPERTIES LABELS "repo" TIMEOUT 120)

  add_test(NAME repo.sdc_portable
    COMMAND "${SOC_IP_PYTHON}" "${CMAKE_CURRENT_SOURCE_DIR}/test_sdc_portable.py"
            --root "${CMAKE_SOURCE_DIR}")
  set_tests_properties(repo.sdc_portable PROPERTIES LABELS "repo" TIMEOUT 120)
endif()
