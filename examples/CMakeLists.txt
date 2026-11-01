#=============================================================================
# examples/ - integration examples that wire several IPs together
#
# Examples are elaborated and linted like any IP, which keeps them compiling
# as the IPs they instantiate evolve. They are the executable half of the
# "usage examples" section of the documentation.
#=============================================================================

file(GLOB _example_dirs RELATIVE "${CMAKE_CURRENT_SOURCE_DIR}"
     "${CMAKE_CURRENT_SOURCE_DIR}/*")

foreach(_dir IN LISTS _example_dirs)
  if(IS_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/${_dir}"
     AND EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/${_dir}/CMakeLists.txt")
    add_subdirectory("${_dir}")
  endif()
endforeach()
