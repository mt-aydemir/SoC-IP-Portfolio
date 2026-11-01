#=============================================================================
# docs/ - Sphinx documentation
#
# The per-IP documentation lives next to each IP under ip/<cat>/<ip>/docs.
# generate_ip_docs.py stages those files into the build tree and produces the
# catalogue index, so the source tree stays free of generated content.
#=============================================================================

if(NOT SOC_IP_SPHINX)
  message(STATUS "docs: sphinx-build not found, documentation target disabled")
  return()
endif()

set(_stage "${SOC_IP_DOC_OUT}/source")
set(_html  "${SOC_IP_DOC_OUT}/html")

add_custom_target(docs
  COMMAND "${SOC_IP_PYTHON}" "${SOC_IP_SCRIPT_DIR}/generate_ip_docs.py"
          --root  "${CMAKE_SOURCE_DIR}"
          --stage "${_stage}"
  COMMAND "${SOC_IP_SPHINX}" -b html -q -W --keep-going
          "${_stage}" "${_html}"
  COMMENT "Building Sphinx documentation -> ${_html}/index.html"
  VERBATIM)

add_custom_target(docs-linkcheck
  COMMAND "${SOC_IP_PYTHON}" "${SOC_IP_SCRIPT_DIR}/generate_ip_docs.py"
          --root  "${CMAKE_SOURCE_DIR}"
          --stage "${_stage}"
  COMMAND "${SOC_IP_SPHINX}" -b linkcheck -q
          "${_stage}" "${SOC_IP_DOC_OUT}/linkcheck"
  COMMENT "Checking documentation links"
  VERBATIM)

add_test(NAME docs.build
  COMMAND "${CMAKE_COMMAND}" --build "${CMAKE_BINARY_DIR}" --target docs)
set_tests_properties(docs.build PROPERTIES LABELS "docs" TIMEOUT 600)
