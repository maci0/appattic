cmake_minimum_required(VERSION 3.16)
project(appattic-qt LANGUAGES C CXX)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE RelWithDebInfo CACHE STRING "Build type" FORCE)
endif()

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)

if(NOT DEFINED ENV{SOURCE_DATE_EPOCH} OR "$ENV{SOURCE_DATE_EPOCH}" STREQUAL "")
    set(ENV{SOURCE_DATE_EPOCH} "0")
endif()

include(CheckPIESupported)
check_pie_supported()
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

find_package(Qt6 REQUIRED COMPONENTS Widgets)
find_package(Threads REQUIRED)

get_filename_component(APPATTIC_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../.." ABSOLUTE)

# The version lives in one place: appAtticVersion in AppAtticScan/Version.swift,
# which the CLI and the macOS UI print. Read it here instead of copying it, so
# the Qt shell cannot ship a different number.
file(READ "${APPATTIC_ROOT}/Sources/AppAtticScan/Version.swift" _appattic_version_source)
string(REGEX MATCH "public let appAtticVersion = \"([0-9]+\\.[0-9]+\\.[0-9]+)\""
       _appattic_version_match "${_appattic_version_source}")
if(NOT _appattic_version_match)
    message(FATAL_ERROR
        "appAtticVersion not found in Sources/AppAtticScan/Version.swift. The Qt build "
        "reads the version from there; keep the declaration intact.")
endif()
set(APPATTIC_VERSION "${CMAKE_MATCH_1}")

if(DEFINED ENV{WASMTIME_DIR} AND NOT WASMTIME_ROOT)
    set(WASMTIME_ROOT "$ENV{WASMTIME_DIR}")
endif()

set(_wasmtime_hints
    "${WASMTIME_ROOT}"
    "/opt/wasmtime-c-api"
    "${APPATTIC_ROOT}/.deps/wasmtime-c-api"
)
if(APPLE)
    list(APPEND _wasmtime_hints "/opt/homebrew" "/usr/local")
endif()

if(WASMTIME_ROOT)
    find_path(WASMTIME_INCLUDE_DIR wasmtime.h
        HINTS "${WASMTIME_ROOT}"
        PATH_SUFFIXES include
        NO_DEFAULT_PATH
    )
    find_library(WASMTIME_LIBRARY NAMES wasmtime
        HINTS "${WASMTIME_ROOT}"
        PATH_SUFFIXES lib lib64
        NO_DEFAULT_PATH
    )
else()
    find_path(WASMTIME_INCLUDE_DIR wasmtime.h
        HINTS ${_wasmtime_hints}
        PATH_SUFFIXES include
    )
    find_library(WASMTIME_LIBRARY NAMES wasmtime
        HINTS ${_wasmtime_hints}
        PATH_SUFFIXES lib lib64
    )
endif()
if(NOT WASMTIME_INCLUDE_DIR OR NOT WASMTIME_LIBRARY)
    message(FATAL_ERROR
        "libwasmtime not found. Install the Wasmtime C API "
        "(scripts/linux-deps.sh --install-wasmtime) or set WASMTIME_DIR.")
endif()

add_library(wasmtime SHARED IMPORTED GLOBAL)
set_target_properties(wasmtime PROPERTIES
    IMPORTED_LOCATION "${WASMTIME_LIBRARY}"
    INTERFACE_INCLUDE_DIRECTORIES "${WASMTIME_INCLUDE_DIR}"
    # The C API tarball ships no SONAME, so ld otherwise records the absolute
    # build path as DT_NEEDED and the installed or bundled binary only runs on
    # the machine that built it.
    IMPORTED_NO_SONAME TRUE
)

# Shared by the app and the helper tests, so they compile it once.
add_library(appattic-qt-core OBJECT
    finding.cpp
    findingmodel.h
    diskusage.cpp
)
target_include_directories(appattic-qt-core PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}"
    "${APPATTIC_ROOT}/core/host"
)
target_link_libraries(appattic-qt-core PRIVATE Qt6::Widgets Threads::Threads)

add_executable(appattic-qt
    main.cpp
    scanworker.h
    scriptproc.h
    scriptproc.cpp
    $<TARGET_OBJECTS:appattic-qt-core>
    settings.cpp
    corehost.cpp
    smoke.cpp
    diskchart.cpp
    diskpage.cpp
    appattic.qrc
    "${APPATTIC_ROOT}/core/host/embed.c"
    "${APPATTIC_ROOT}/core/host/hostexec.c"
)
target_include_directories(appattic-qt PRIVATE
    "${APPATTIC_ROOT}/core/host"
    "${WASMTIME_INCLUDE_DIR}"
)
# Do not bake the configure-time source path into the binary. Runtime uses
# APPATTIC_CORE_OUT, then paths relative to the executable (see coreOutDir).
target_link_libraries(appattic-qt PRIVATE Qt6::Widgets wasmtime Threads::Threads)
# The same value the CLI and the macOS UI print, read from Version.swift above.
target_compile_definitions(appattic-qt PRIVATE APPATTIC_VERSION="${APPATTIC_VERSION}")
if(CMAKE_C_COMPILER_ID MATCHES "GNU|Clang")
    # core/build-flags.sh is the one shell-side list of these flags, shared by
    # core/build.sh and scripts/verify-reproducible.sh. CMake cannot read it, so
    # this block is the one copy that has to be kept in step by hand: a flag
    # added there belongs here too.
    # One list, applied to every target whose objects end up in the shipped
    # binary. appattic-qt-core is an OBJECT library: target_compile_options on
    # appattic-qt does not reach its translation units, so finding.cpp and
    # diskusage.cpp would otherwise link into the release without the stack
    # protector, without FORTIFY, and with the build path left in their debug
    # info.
    set(_appattic_hardening_cflags
        -fstack-protector-strong
        -Wformat
        -Wformat-security
        -Werror=format-security
        "-ffile-prefix-map=${APPATTIC_ROOT}=."
        "-fdebug-prefix-map=${APPATTIC_ROOT}=."
        "-fmacro-prefix-map=${APPATTIC_ROOT}=."
        "-ffile-prefix-map=${CMAKE_BINARY_DIR}=/build"
        "-fdebug-prefix-map=${CMAKE_BINARY_DIR}=/build"
        "-fmacro-prefix-map=${CMAKE_BINARY_DIR}=/build"
        $<$<COMPILE_LANGUAGE:C>:-Wall>
        $<$<COMPILE_LANGUAGE:C>:-Wextra>
    )
    # KDE/Flatpak SDKs already pass -Wp,-D_FORTIFY_SOURCE=3. Re-defining it
    # with -Werror fails GCC 15.
    if(NOT DEFINED ENV{FLATPAK_DEST})
        list(APPEND _appattic_hardening_cflags
            $<$<NOT:$<CONFIG:Debug>>:-U_FORTIFY_SOURCE>
            $<$<NOT:$<CONFIG:Debug>>:-D_FORTIFY_SOURCE=2>
        )
    endif()
    if(UNIX AND NOT APPLE)
        list(APPEND _appattic_hardening_cflags -fstack-clash-protection)
        set(_appattic_hardening_ldflags
            -pie
            -Wl,-z,relro,-z,now
            -Wl,-z,noexecstack
        )
        if(CMAKE_SYSTEM_PROCESSOR MATCHES "x86_64|amd64|AMD64")
            list(APPEND _appattic_hardening_cflags -fcf-protection=full)
            list(APPEND _appattic_hardening_ldflags -fcf-protection=full)
        elseif(CMAKE_SYSTEM_PROCESSOR MATCHES "aarch64|ARM64|arm64")
            list(APPEND _appattic_hardening_cflags -mbranch-protection=standard)
        endif()
    endif()
    target_compile_options(appattic-qt PRIVATE ${_appattic_hardening_cflags})
    target_compile_options(appattic-qt-core PRIVATE ${_appattic_hardening_cflags})
    if(UNIX AND NOT APPLE)
        target_link_options(appattic-qt PRIVATE ${_appattic_hardening_ldflags})
    endif()
    # Every C source this target compiles gets the strict set core/build.sh
    # already builds them with, so the two builds cannot disagree.
    foreach(_src IN ITEMS
            "${APPATTIC_ROOT}/core/host/hostexec.c"
            "${APPATTIC_ROOT}/core/host/embed.c")
        set_property(SOURCE "${_src}"
            APPEND PROPERTY COMPILE_OPTIONS
            -Werror -Wformat=2 -Wformat-security -Wshadow
            -Wstrict-prototypes -Wconversion -Wpedantic -Wnull-dereference)
    endforeach()
endif()
if(CMAKE_CXX_COMPILER_ID MATCHES "GNU|Clang")
    target_compile_options(appattic-qt-core PRIVATE
        $<$<COMPILE_LANGUAGE:CXX>:-Wall>
        $<$<COMPILE_LANGUAGE:CXX>:-Wextra>
        $<$<AND:$<COMPILE_LANGUAGE:CXX>,$<NOT:$<CONFIG:Debug>>>:-D_GLIBCXX_ASSERTIONS>
    )
    target_compile_options(appattic-qt PRIVATE
        $<$<COMPILE_LANGUAGE:CXX>:-Wall>
        $<$<COMPILE_LANGUAGE:CXX>:-Wextra>
        $<$<AND:$<COMPILE_LANGUAGE:CXX>,$<NOT:$<CONFIG:Debug>>>:-D_GLIBCXX_ASSERTIONS>
    )
    # Source-level so a separate AUTOMOC TU does not inherit -Werror. The list
    # is every C++ source in this directory: a file left out of it builds with
    # warnings nobody fails on.
    set(_appattic_werror_cxx
        main.cpp corehost.cpp finding.cpp settings.cpp smoke.cpp
        diskusage.cpp diskchart.cpp diskpage.cpp)
    foreach(_src IN LISTS _appattic_werror_cxx)
        set_property(SOURCE "${_src}" APPEND PROPERTY COMPILE_OPTIONS -Werror)
    endforeach()
    file(GLOB _appattic_ui_cxx CONFIGURE_DEPENDS
        "${CMAKE_CURRENT_SOURCE_DIR}/*.cpp"
        "${CMAKE_CURRENT_SOURCE_DIR}/tests/*.cpp")
    foreach(_path IN LISTS _appattic_ui_cxx)
        get_filename_component(_name "${_path}" NAME)
        # tests/helper_tests.cpp carries -Werror on its own target below.
        if(_name MATCHES "^helper_tests\\.cpp$" OR
           _name IN_LIST _appattic_werror_cxx)
            continue()
        endif()
        message(FATAL_ERROR
            "${_name} is a C++ source of this UI but is missing from "
            "_appattic_werror_cxx, so it would build without -Werror.")
    endforeach()
endif()
if(UNIX AND NOT APPLE)
    get_filename_component(_wasmtime_libdir "${WASMTIME_LIBRARY}" DIRECTORY)
    set_target_properties(appattic-qt PROPERTIES
        BUILD_RPATH "${_wasmtime_libdir}"
        INSTALL_RPATH "\$ORIGIN:\$ORIGIN/../lib"
        BUILD_WITH_INSTALL_RPATH OFF
        INSTALL_RPATH_USE_LINK_PATH OFF
        POSITION_INDEPENDENT_CODE ON
    )
endif()

install(TARGETS appattic-qt RUNTIME DESTINATION bin)
# The .cwasm images are what core/build.sh --precompile writes beside the
# wasm, and the .stamp is what binds each image to the wasm it was built from:
# core/host/embed.c deserializes an image only when its stamp matches, so an
# install that ships only the wasm (or the images without the stamps) makes
# every first scan pay the compile.
install(DIRECTORY "${APPATTIC_ROOT}/core/out/"
    DESTINATION share/appattic
    FILES_MATCHING
        PATTERN "*.wasm"
        PATTERN "*.cwasm"
        PATTERN "*.cwasm.stamp"
)

# The Michroma font is compiled into the binary, so its SIL OFL grant has to
# reach the artifact as well: the license is a condition of using the font, and
# shipping only the .ttf drops it. Every license text in the vendored font
# directory is installed, because scripts/deps.sh check fails on a font with no
# grant beside it, and a second font brings its own.
file(GLOB _appattic_font_licenses "${CMAKE_CURRENT_SOURCE_DIR}/fonts/*.txt")
foreach(_font_license IN LISTS _appattic_font_licenses)
    install(FILES "${_font_license}" DESTINATION share/appattic/licenses)
endforeach()

# Helper coverage for finding.cpp, diskusage.cpp, and settings.cpp. It needs no
# scan and no wasm host, so it lives in its own binary instead of the shipped
# app. settings.cpp is here, not only on the app target: checkSettings() calls
# parseSettingsJson and legacyBoolValue, so the test binary does not link
# without it.
add_executable(appattic-qt-helper-tests
    tests/helper_tests.cpp
    $<TARGET_OBJECTS:appattic-qt-core>
    settings.cpp
    appattic.qrc
)
target_include_directories(appattic-qt-helper-tests PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}"
    "${APPATTIC_ROOT}/core/host"
)
target_link_libraries(appattic-qt-helper-tests PRIVATE Qt6::Widgets Threads::Threads)
target_compile_definitions(appattic-qt-helper-tests PRIVATE APPATTIC_VERSION="${APPATTIC_VERSION}")
# Same flags as the app, so the tests cannot compile under a looser policy.
get_target_property(_appattic_compile_options appattic-qt COMPILE_OPTIONS)
if(_appattic_compile_options)
    target_compile_options(appattic-qt-helper-tests PRIVATE ${_appattic_compile_options})
endif()
set_property(SOURCE tests/helper_tests.cpp APPEND PROPERTY COMPILE_OPTIONS -Werror)

if(EXISTS "${APPATTIC_ROOT}/packaging/org.appattic.AppAttic.desktop")
    install(FILES "${APPATTIC_ROOT}/packaging/org.appattic.AppAttic.desktop"
        DESTINATION share/applications)
endif()
if(EXISTS "${APPATTIC_ROOT}/packaging/appattic.svg")
    install(FILES "${APPATTIC_ROOT}/packaging/appattic.svg"
        DESTINATION share/icons/hicolor/scalable/apps)
endif()
if(EXISTS "${APPATTIC_ROOT}/packaging/appattic.png")
    install(FILES "${APPATTIC_ROOT}/packaging/appattic.png"
        DESTINATION share/icons/hicolor/128x128/apps)
endif()
if(EXISTS "${APPATTIC_ROOT}/packaging/org.appattic.AppAttic.metainfo.xml")
    install(FILES "${APPATTIC_ROOT}/packaging/org.appattic.AppAttic.metainfo.xml"
        DESTINATION share/metainfo)
endif()
if(EXISTS "${APPATTIC_ROOT}/packaging/appattic-qt.1")
    install(FILES "${APPATTIC_ROOT}/packaging/appattic-qt.1"
        DESTINATION share/man/man1)
endif()
