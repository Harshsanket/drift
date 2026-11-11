cmake_minimum_required(VERSION 3.20)
project(drift-engine LANGUAGES CXX)

# Drift embedded torrent engine (EMBEDDED-ENGINE.md §4, D19/D20).
# The engine is a standalone C++17 executable. Everything under engine/ is
# BSD-3 only: libtorrent is vendored as a pinned submodule; qBittorrent and
# search-plugins sources are never built, linked, or bundled here.

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OSX_DEPLOYMENT_TARGET "26.0" CACHE STRING "macOS deployment target")

# D20: arm64-only distribution.
if(APPLE AND NOT CMAKE_OSX_ARCHITECTURES)
  set(CMAKE_OSX_ARCHITECTURES arm64)
endif()

# Static libtorrent, no optional tooling compiled into our build.
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(build_tests OFF CACHE BOOL "" FORCE)
set(build_examples OFF CACHE BOOL "" FORCE)
set(build_tools OFF CACHE BOOL "" FORCE)
set(python-bindings OFF CACHE BOOL "" FORCE)
set(webtorrent OFF CACHE BOOL "" FORCE)

# Homebrew is the supported build environment on this Mac (README).
find_package(Boost 1.70 REQUIRED COMPONENTS json)
find_package(OpenSSL REQUIRED)

add_subdirectory(third_party/libtorrent EXCLUDE_FROM_ALL)

add_executable(drift-engine src/main.cpp)
target_link_libraries(drift-engine PRIVATE torrent-rasterbar Boost::json OpenSSL::SSL OpenSSL::Crypto)
target_compile_definitions(drift-engine PRIVATE
  DRIFT_ENGINE_VERSION="0.1.0"
  LIBTORRENT_VERSION_STRING="${LIBTORRENT_VERSION}"
)

install(TARGETS drift-engine RUNTIME DESTINATION .)
