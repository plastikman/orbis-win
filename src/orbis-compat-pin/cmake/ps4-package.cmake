# PS4 .pkg packaging for OpenOrbis targets. Included by cmake/ps4-openorbis.cmake.
#
#   ps4_create_pkg(<target>
#     TITLE_ID      TMPS10001            # AAAA00000; TMPS1xxxx is this fork's range
#     TITLE         "Tempest Hello"
#     [VERSION      01.00]
#     [CONTENT_LABEL TEMPESTHELLO]       # <=16 chars, [A-Z0-9], padded with zeros
#     [ICON         icon0.png]           # 512x512 PNG; default: a tile generated from TITLE_ID
#     [EXTRA_FILES  <src>:<targ_path> ...])
#
# Appends POST_BUILD steps that turn the target's eboot.bin (produced by
# ps4_create_eboot) into <build>/IV0000-<TITLE_ID>_00-<LABEL>.pkg plus a
# <TITLE_ID>.pkg symlink. The actual SDK tool sequence lives in
# scripts/ps4/make-pkg.sh — that script is also usable standalone.
#
# Set -DPS4_BUILD_PKG=OFF to build only the ELF/eboot (emulator runs need no pkg).

if(DEFINED PS4_PACKAGE_CMAKE_INCLUDED)
  return()
endif()
set(PS4_PACKAGE_CMAKE_INCLUDED TRUE)

option(PS4_BUILD_PKG "Build a .pkg for every PS4 executable target" ON)

# ⚠ THE SCRIPTS ARE NOT NEXT TO THIS FILE ANY MORE. This was "../scripts/ps4", which was true while
# cmake/ and scripts/ lived in one repository; cmake/ moved to the porting kit on 2026-09-18 and
# scripts/ps4/ stayed in the overlay, so that path silently became kit/scripts/ps4 - which exists and
# does NOT hold make-pkg.sh. The failure was a ninja error naming a missing file at the END of a
# successful build, which is a long way from the line that chose the path.
#
# Resolved in order, and the sibling is LAST rather than first so that moving the scripts later
# needs no third edit here.
set(PS4_PACKAGE_SCRIPT_DIR "")
foreach(_cand
    "${ORBIS_COMPAT_DIR}/scripts/ps4"          # where make-pkg.sh lives today
    "$ENV{ORBIS_COMPAT_DIR}/scripts/ps4"
    "${ORBIS_KIT_DIR}/scripts/ps4"             # if they ever move to the kit
    "$ENV{ORBIS_KIT_DIR}/scripts/ps4"
    "${CMAKE_CURRENT_LIST_DIR}/../scripts/ps4")
  if(_cand AND EXISTS "${_cand}/make-pkg.sh")
    get_filename_component(PS4_PACKAGE_SCRIPT_DIR "${_cand}" ABSOLUTE)
    break()
  endif()
endforeach()
if(NOT PS4_PACKAGE_SCRIPT_DIR)
  # Not fatal at include time: a project that never calls ps4_create_pkg() does not need this, and
  # a configure-time refusal would block builds that are fine. ps4_create_pkg() names it below.
  get_filename_component(PS4_PACKAGE_SCRIPT_DIR "${CMAKE_CURRENT_LIST_DIR}/../scripts/ps4" ABSOLUTE)
endif()

function(ps4_create_pkg target)
  if(NOT PS4_BUILD_PKG)
    return()
  endif()
  if(NOT EXISTS "${PS4_PACKAGE_SCRIPT_DIR}/make-pkg.sh")
    message(FATAL_ERROR
      "ps4_create_pkg(${target}) needs make-pkg.sh and looked in '${PS4_PACKAGE_SCRIPT_DIR}'. "
      "Set ORBIS_COMPAT_DIR to the orbis-compat checkout (it ships scripts/ps4/), or turn "
      "PS4_BUILD_PKG off. Failing here rather than at the end of the build, where it reads as a "
      "missing ninja rule.")
  endif()

  cmake_parse_arguments(ARG "" "TITLE_ID;TITLE;VERSION;CONTENT_LABEL;ICON" "EXTRA_FILES" ${ARGN})
  if(NOT ARG_TITLE_ID)
    message(FATAL_ERROR "ps4_create_pkg(${target}): TITLE_ID is required")
  endif()
  if(NOT ARG_TITLE)
    message(FATAL_ERROR "ps4_create_pkg(${target}): TITLE is required")
  endif()
  if(NOT ARG_VERSION)
    set(ARG_VERSION "01.00")
  endif()
  if(NOT ARG_CONTENT_LABEL)
    set(ARG_CONTENT_LABEL "${ARG_TITLE_ID}")
  endif()

  find_program(PS4_PKGTOOL NAMES PkgTool.Core PATHS "${OO_PS4_BINDIR}" NO_DEFAULT_PATH)
  if(NOT PS4_PKGTOOL)
    message(WARNING
      "PkgTool.Core not found in ${OO_PS4_BINDIR}; skipping .pkg for ${target}. "
      "The ELF and eboot.bin still build.")
    return()
  endif()

  # A title's own icon wins. It must already be what the console wants - 512x512 PNG - since nothing
  # here converts it. LINK_DEPENDS because the package is a POST_BUILD step: without it a changed icon
  # would wait for the next code change to reach a .pkg.
  #
  # Otherwise icon0.png depends only on TITLE_ID, so it is generated once at configure time
  # rather than re-running the pure-python encoder on every build.
  set(_icon "")
  find_program(PS4_PYTHON3 NAMES python3 python)
  if(ARG_ICON)
    get_filename_component(_icon "${ARG_ICON}" ABSOLUTE BASE_DIR "${CMAKE_CURRENT_SOURCE_DIR}")
    if(NOT EXISTS "${_icon}")
      message(FATAL_ERROR "ps4_create_pkg(${target}): ICON ${_icon} does not exist")
    endif()
    set_property(TARGET ${target} APPEND PROPERTY LINK_DEPENDS "${_icon}")
  elseif(PS4_PYTHON3)
    set(_icon "${CMAKE_CURRENT_BINARY_DIR}/pkg-assets/icon0.png")
    file(MAKE_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/pkg-assets")
    execute_process(
      COMMAND "${PS4_PYTHON3}" "${PS4_PACKAGE_SCRIPT_DIR}/gen-icon0.py"
              --out "${_icon}" --title-id "${ARG_TITLE_ID}"
      RESULT_VARIABLE _icon_rc
      OUTPUT_QUIET)
    if(NOT _icon_rc EQUAL 0)
      message(WARNING "gen-icon0.py failed (${_icon_rc}); packaging ${target} without icon0.png")
      set(_icon "")
    endif()
  else()
    message(STATUS "python3 not found; packaging ${target} without icon0.png")
  endif()

  set(_args
    --eboot   "$<TARGET_FILE_DIR:${target}>/eboot.bin"
    --out-dir "$<TARGET_FILE_DIR:${target}>"
    --title-id "${ARG_TITLE_ID}"
    --title    "${ARG_TITLE}"
    --version  "${ARG_VERSION}"
    --content-label "${ARG_CONTENT_LABEL}"
    --sdk      "${OO_PS4_TOOLCHAIN}")
  if(_icon)
    list(APPEND _args --icon "${_icon}")
  endif()
  foreach(_extra IN LISTS ARG_EXTRA_FILES)
    list(APPEND _args --extra "${_extra}")
  endforeach()

  add_custom_command(TARGET ${target} POST_BUILD
    COMMAND "${PS4_PACKAGE_SCRIPT_DIR}/make-pkg.sh" ${_args}
    VERBATIM
    COMMENT "pkg: ${target} -> IV0000-${ARG_TITLE_ID}_00-*.pkg")
endfunction()
