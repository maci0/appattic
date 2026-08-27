cmake_minimum_required(VERSION 3.16)
project(appattic-qt LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_C_STANDARD 11)
set(CMAKE_AUTOMOC ON)

find_package(Qt6 REQUIRED COMPONENTS Widgets)

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
    "${APPATTIC_ROOT}/core/host/embed.c"
    "${APPATTIC_ROOT}/core/host/hostexec.c"
)
target_include_directories(appattic-qt PRIVATE
    "${APPATTIC_ROOT}/core/host"
    "${WASMTIME_INCLUDE_DIR}"
)
target_compile_definitions(appattic-qt PRIVATE
    APPATTIC_CORE_OUT="${APPATTIC_ROOT}/core/out"
)
target_link_libraries(appattic-qt PRIVATE Qt6::Widgets wasmtime)
if(UNIX AND NOT APPLE)
    get_filename_component(_wasmtime_libdir "${WASMTIME_LIBRARY}" DIRECTORY)
    set_target_properties(appattic-qt PROPERTIES
        BUILD_RPATH "${_wasmtime_libdir}"
        INSTALL_RPATH "\$ORIGIN"
        BUILD_WITH_INSTALL_RPATH OFF
        INSTALL_RPATH_USE_LINK_PATH OFF
    )
endif()

install(TARGETS appattic-qt RUNTIME DESTINATION bin)

if(EXISTS "${APPATTIC_ROOT}/packaging/appattic.desktop")
    install(FILES "${APPATTIC_ROOT}/packaging/appattic.desktop"
        DESTINATION share/applications)
endif()
if(EXISTS "${APPATTIC_ROOT}/packaging/appattic.svg")
    install(FILES "${APPATTIC_ROOT}/packaging/appattic.svg"
        DESTINATION share/icons/hicolor/scalable/apps)
endif()
