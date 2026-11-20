# orbis_patch_source() - apply the kit's patch registry to a tree CMake fetched itself.
#
# ⚠ WHY THIS EXISTS BESIDE scripts/orbis-patch.sh RATHER THAN INSTEAD OF IT. A shell harness
# patches between "clone" and "build", and that window does not exist for a project whose sources
# arrive during configure. patches/libretro/melondsds/0004 is the measured case: melonDS-DS pulls
# its dependencies with FetchContent, so the trees are created by cmake itself and RetroArch's
# ps4/build-cores.sh cannot reach them at all - the patch has to ride on the project's own
# FetchDependencies.cmake. Any engine that fetches at configure time has the same shape.
#
# Usage, as a FetchContent step - PATCH_COMMAND runs in the fetched source directory:
#
#   include("$ENV{ORBIS_KIT_DIR}/cmake/OrbisPatch.cmake")
#   FetchContent_Declare(foo GIT_REPOSITORY ... PATCH_COMMAND ${ORBIS_PATCH_COMMAND} libretro/foo .)
#
# or explicitly, for a tree that is already on disk:
#
#   orbis_patch_source(libretro/melondsds "${melonds_SOURCE_DIR}")
#
# ⚠ AND IT IS IDEMPOTENT BY CHECKING, NOT BY REMEMBERING. FetchContent re-runs PATCH_COMMAND
# whenever it re-populates, and a second `git apply` of an applied patch fails - which would read
# as a stale patch rather than as a patch that is already in. `git apply --reverse --check`
# answers "is this already applied?" without a stamp file that a `rm -rf build` would desynchronise.
#
# SPDX-License-Identifier: MIT

if(DEFINED ORBIS_PATCH_INCLUDED)
  return()
endif()
set(ORBIS_PATCH_INCLUDED TRUE)

# The kit is the directory above this file; a caller that set ORBIS_KIT_DIR keeps its own answer.
if(NOT ORBIS_KIT_DIR)
  get_filename_component(ORBIS_KIT_DIR "${CMAKE_CURRENT_LIST_DIR}/.." ABSOLUTE)
endif()
set(ORBIS_PATCH_REGISTRY "${ORBIS_KIT_DIR}/patches" CACHE PATH "Where the kit's patch series live")
set(ORBIS_PATCH_COMMAND "${CMAKE_COMMAND}" -DORBIS_KIT_DIR=${ORBIS_KIT_DIR}
    -P "${CMAKE_CURRENT_LIST_DIR}/OrbisPatchStep.cmake" --
    CACHE STRING "Prefix for a FetchContent PATCH_COMMAND; append <family>/<project> <srcdir>")

# Read a SERIES file the way scripts/orbis-patch.sh reads it: `patch:` lines, in file order.
function(orbis_patch_series out_var series_file)
  set(_names "")
  if(NOT EXISTS "${series_file}")
    message(FATAL_ERROR "orbis_patch: no SERIES at ${series_file}")
  endif()
  file(STRINGS "${series_file}" _lines)
  foreach(_l IN LISTS _lines)
    string(REGEX REPLACE "[ \t]*#.*$" "" _l "${_l}")
    if(_l MATCHES "^patch:[ \t]*(.+)$")
      string(STRIP "${CMAKE_MATCH_1}" _n)
      list(APPEND _names "${_n}")
    endif()
  endforeach()
  set(${out_var} "${_names}" PARENT_SCOPE)
endfunction()

function(orbis_patch_source project srcdir)
  set(_dir "${ORBIS_PATCH_REGISTRY}/${project}")
  if(NOT IS_DIRECTORY "${_dir}")
    message(FATAL_ERROR "orbis_patch: no series ${project} under ${ORBIS_PATCH_REGISTRY}")
  endif()
  find_package(Git REQUIRED)
  orbis_patch_series(_patches "${_dir}/SERIES")
  set(_applied 0)
  foreach(_p IN LISTS _patches)
    if(NOT EXISTS "${_dir}/${_p}")
      message(FATAL_ERROR "orbis_patch: ${project}'s SERIES names ${_p} and it is not there")
    endif()
    # Already in? Then a reverse application would succeed, and there is nothing to do.
    execute_process(COMMAND "${GIT_EXECUTABLE}" apply --reverse --check "${_dir}/${_p}"
                    WORKING_DIRECTORY "${srcdir}" RESULT_VARIABLE _rev
                    OUTPUT_QUIET ERROR_QUIET)
    if(_rev EQUAL 0)
      message(STATUS "orbis_patch: ${project}/${_p} already applied")
      continue()
    endif()
    execute_process(COMMAND "${GIT_EXECUTABLE}" apply --whitespace=nowarn "${_dir}/${_p}"
                    WORKING_DIRECTORY "${srcdir}" RESULT_VARIABLE _rc
                    ERROR_VARIABLE _err)
    if(NOT _rc EQUAL 0)
      message(FATAL_ERROR "orbis_patch: ${project}/${_p} would not apply to ${srcdir}\n${_err}")
    endif()
    math(EXPR _applied "${_applied}+1")
  endforeach()
  message(STATUS "orbis_patch: ${project} - ${_applied} patch(es) applied in ${srcdir}")
endfunction()
