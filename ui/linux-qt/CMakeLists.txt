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
)

add_executable(appattic-qt
    main.cpp
    finding.cpp
    settings.cpp
    corehost.cpp
    smoke.cpp
    diskusage.cpp
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
if(CMAKE_C_COMPILER_ID MATCHES "GNU|Clang")
    target_compile_options(appattic-qt PRIVATE
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
        target_compile_options(appattic-qt PRIVATE
            $<$<NOT:$<CONFIG:Debug>>:-U_FORTIFY_SOURCE>
            $<$<NOT:$<CONFIG:Debug>>:-D_FORTIFY_SOURCE=2>
        )
    endif()
    if(UNIX AND NOT APPLE)
        target_compile_options(appattic-qt PRIVATE -fstack-clash-protection)
        target_link_options(appattic-qt PRIVATE
            -pie
            -Wl,-z,relro,-z,now
            -Wl,-z,noexecstack
        )
        if(CMAKE_SYSTEM_PROCESSOR MATCHES "x86_64|amd64|AMD64")
            target_compile_options(appattic-qt PRIVATE -fcf-protection=full)
            target_link_options(appattic-qt PRIVATE -fcf-protection=full)
        elseif(CMAKE_SYSTEM_PROCESSOR MATCHES "aarch64|ARM64|arm64")
            target_compile_options(appattic-qt PRIVATE -mbranch-protection=standard)
        endif()
    endif()
    set_property(SOURCE "${APPATTIC_ROOT}/core/host/hostexec.c"
        APPEND PROPERTY COMPILE_OPTIONS
        -Werror -Wformat=2 -Wformat-security -Wshadow
        -Wstrict-prototypes -Wconversion -Wpedantic -Wnull-dereference)
endif()
if(CMAKE_CXX_COMPILER_ID MATCHES "GNU|Clang")
    target_compile_options(appattic-qt PRIVATE
        $<$<COMPILE_LANGUAGE:CXX>:-Wall>
        $<$<COMPILE_LANGUAGE:CXX>:-Wextra>
        $<$<AND:$<COMPILE_LANGUAGE:CXX>,$<NOT:$<CONFIG:Debug>>>:-D_GLIBCXX_ASSERTIONS>
    )
    # Source-level so a separate AUTOMOC TU does not inherit -Werror.
    set_property(SOURCE main.cpp finding.cpp settings.cpp smoke.cpp
        diskusage.cpp diskchart.cpp diskpage.cpp
        APPEND PROPERTY COMPILE_OPTIONS -Werror)
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
install(DIRECTORY "${APPATTIC_ROOT}/core/out/"
    DESTINATION share/appattic
    FILES_MATCHING PATTERN "*.wasm"
)

if(EXISTS "${APPATTIC_ROOT}/packaging/appattic.desktop")
    install(FILES "${APPATTIC_ROOT}/packaging/appattic.desktop"
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
