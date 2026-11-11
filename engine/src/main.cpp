// drift-engine — libtorrent helper process for Drift (Stage B, E1).
#include "engine.hpp"
#include "uds_server.hpp"

#include <boost/json.hpp>

#include <atomic>
#include <chrono>
#include <csignal>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <iostream>
#include <string>
#include <thread>

#include <unistd.h>

namespace drift {
bool runSelfTest(std::string const& root, std::string& error);
}

namespace {

std::atomic<bool> g_stop{false};
std::atomic<std::int64_t> g_lastTick{0};

std::int64_t unixNow() {
  return std::chrono::duration_cast<std::chrono::seconds>(
             std::chrono::system_clock::now().time_since_epoch())
      .count();
}

void requestStop(int) { g_stop = true; }

std::string defaultStateDir() {
  char const* home = std::getenv("HOME");
  return std::string(home != nullptr ? home : ".") + "/Library/Application Support/Drift/engine";
}

void usage() {
  std::cout
      << "usage: drift-engine [options]\n"
      << "  --state-dir PATH       state directory (default: ~/Library/Application Support/Drift/engine)\n"
      << "  --socket PATH          Unix socket path (default: <state-dir>/engine.sock)\n"
      << "  --save-path PATH       default download directory\n"
      << "  --listen-port N        BitTorrent listen port (0 = random/ephemeral)\n"
      << "  --watchdog-seconds N   heartbeat timeout (default 15)\n"
      << "  --idle-exit-seconds N  exit after the last client leaves (default 15)\n"
      << "  --selftest             run the E1 loopback download/resume test\n"
      << "  --version              print version\n";
}

}  // namespace

int main(int argc, char** argv) {
  std::string stateDir = defaultStateDir();
  std::string socketPath;
  std::string savePath;
  int listenPort = 0;
  int watchdogSeconds = 15;
  int idleExitSeconds = 15;
  bool selftest = false;

  for (int i = 1; i < argc; ++i) {
    std::string arg = argv[i];
    auto next = [&](std::string& target) {
      if (i + 1 < argc) target = argv[++i];
    };
    if (arg == "--state-dir") next(stateDir);
    else if (arg == "--socket") next(socketPath);
    else if (arg == "--save-path") next(savePath);
    else if (arg == "--listen-port") {
      std::string value;
      next(value);
      listenPort = std::atoi(value.c_str());
    } else if (arg == "--watchdog-seconds") {
      std::string value;
      next(value);
      watchdogSeconds = std::atoi(value.c_str());
    } else if (arg == "--idle-exit-seconds") {
      std::string value;
      next(value);
      idleExitSeconds = std::atoi(value.c_str());
    } else if (arg == "--selftest") selftest = true;
    else if (arg == "--version") {
      std::cout << "drift-engine " DRIFT_ENGINE_VERSION " (libtorrent " LIBTORRENT_VERSION ")\n";
      return 0;
    } else if (arg == "--help" || arg == "-h") {
      usage();
      return 0;
    } else {
      std::cerr << "unknown argument: " << arg << "\n";
      usage();
      return 2;
    }
  }

  if (socketPath.empty()) socketPath = stateDir + "/engine.sock";

  if (selftest) {
    std::string error;
    try {
      if (!drift::runSelfTest(stateDir, error)) {
        std::cerr << "SELFTEST FAIL: " << error << std::endl;
        return 1;
      }
    } catch (std::exception const& e) {
      std::cerr << "SELFTEST EXCEPTION: " << e.what() << std::endl;
      return 1;
    }
    std::cout.flush();
    std::cerr.flush();
    std::_Exit(0);
  }

  std::signal(SIGPIPE, SIG_IGN);
  std::signal(SIGINT, requestStop);
  std::signal(SIGTERM, requestStop);

  drift::EngineConfig config;
  config.savePath = savePath;
  config.listenPort = listenPort;
  drift::Engine engine(stateDir, config);
  std::string error;
  if (!engine.init(error)) {
    std::cerr << "drift-engine: " << error << "\n";
    return 1;
  }

  drift::UdsServer server;
  engine.setEmitter([&](boost::json::object message) { server.send(message); });
  if (!server.start(socketPath, [&](boost::json::object const& request) {
        return engine.handle(request);
      }, error)) {
    std::cerr << "drift-engine: " << error << "\n";
    engine.shutdown();
    return 1;
  }

  std::cout << "drift-engine ready pid=" << ::getpid()
            << " port=" << engine.listenPort()
            << " socket=" << socketPath << std::endl;

  g_lastTick = unixNow();
  std::thread watchdog([&] {
    while (!g_stop) {
      std::this_thread::sleep_for(std::chrono::seconds(1));
      auto const now = unixNow();
      if (now - g_lastTick > watchdogSeconds) {
        std::cerr << "drift-engine: watchdog fired (main loop stalled "
                  << (now - g_lastTick) << "s)" << std::endl;
        ::_exit(70);
      }
      if (server.hasClient()) {
        auto const last = server.lastClientFrame();
        if (last > 0 && now - last > watchdogSeconds) {
          std::cerr << "drift-engine: watchdog fired (client silent "
                    << (now - last) << "s)" << std::endl;
          ::_exit(71);
        }
      }
    }
  });

  bool hadClient = false;
  std::int64_t lastClientSeen = unixNow();
  auto const startedAt = unixNow();
  while (!g_stop) {
    server.poll(50);
    engine.tick();
    g_lastTick = unixNow();
    if (server.hasClient()) {
      hadClient = true;
      lastClientSeen = g_lastTick;
    } else if (g_lastTick - lastClientSeen > idleExitSeconds) {
      std::cerr << "drift-engine: no client for " << idleExitSeconds
                << "s, shutting down" << std::endl;
      g_stop = true;
    } else if (!hadClient && g_lastTick - startedAt > idleExitSeconds) {
      std::cerr << "drift-engine: no client connected within " << idleExitSeconds
                << "s, shutting down" << std::endl;
      g_stop = true;
    }
  }

  g_stop = true;
  if (watchdog.joinable()) watchdog.join();
  server.stop();
  engine.shutdown();
  std::cout << "drift-engine stopped" << std::endl;
  std::cout.flush();
  std::cerr.flush();
  // libtorrent's session destructor can block on shutdown of its network
  // threads; the state is already saved, so exit deterministically instead
  // of leaving an orphan engine behind.
  std::_Exit(0);
}
