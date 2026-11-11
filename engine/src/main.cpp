// Drift embedded engine — E0 skeleton.
// The full JSON-lines/UDS service lands in E1 (EMBEDDED-ENGINE.md §6).
#include <libtorrent/version.hpp>

#include <cstdio>
#include <string>

int main(int argc, char** argv) {
  for (int i = 1; i < argc; ++i) {
    std::string arg = argv[i];
    if (arg == "--version") {
      std::printf("drift-engine %s (libtorrent %s)\n", DRIFT_ENGINE_VERSION,
                  libtorrent::version());
      return 0;
    }
  }
  std::printf("drift-engine %s (libtorrent %s)\n", DRIFT_ENGINE_VERSION,
              libtorrent::version());
  return 0;
}
