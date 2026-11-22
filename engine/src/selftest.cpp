// SPDX-License-Identifier: BSD-3-Clause
// E1 acceptance harness: create a torrent, seed it in a private session, add
// it to the engine as a magnet, download it over loopback, then restart the
// engine and verify the resume data restored the transfer.
#include "engine.hpp"

#include <libtorrent/alert_types.hpp>
#include <libtorrent/bencode.hpp>
#include <libtorrent/create_torrent.hpp>
#include <libtorrent/magnet_uri.hpp>
#include <libtorrent/session.hpp>
#include <libtorrent/settings_pack.hpp>
#include <libtorrent/torrent_info.hpp>

#include <chrono>
#include <algorithm>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <functional>
#include <iostream>
#include <iterator>
#include <thread>

#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

namespace drift {
namespace {

namespace fs = std::filesystem;
using namespace std::chrono_literals;

int freePort() {
  int fd = ::socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) return 0;
  sockaddr_in addr{};
  addr.sin_family = AF_INET;
  addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  addr.sin_port = 0;
  int port = 0;
  if (::bind(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) == 0) {
    socklen_t len = sizeof(addr);
    if (::getsockname(fd, reinterpret_cast<sockaddr*>(&addr), &len) == 0) {
      port = ntohs(addr.sin_port);
    }
  }
  ::close(fd);
  return port;
}

void drain(lt::session& session) {
  std::vector<lt::alert*> alerts;
  session.pop_alerts(&alerts);
}

bool waitFor(std::chrono::seconds timeout, std::function<bool()> const& predicate) {
  auto const deadline = std::chrono::steady_clock::now() + timeout;
  while (std::chrono::steady_clock::now() < deadline) {
    if (predicate()) return true;
    std::this_thread::sleep_for(100ms);
  }
  return predicate();
}

}  // namespace

bool runSelfTest(std::string const& root, std::string& error) {
  auto const base = fs::path(root) / "selftest";
  lt::error_code ec;
  std::error_code fsEc;
  fs::remove_all(base, fsEc);
  fs::create_directories(base / "seed", fsEc);
  fs::create_directories(base / "download", fsEc);
  fs::create_directories(base / "state", fsEc);
  if (fsEc) {
    error = "selftest: cannot create directories: " + fsEc.message();
    return false;
  }

  // 512 KiB payload, 16 KiB pieces.
  constexpr std::size_t kSize = 512 * 1024;
  std::vector<char> payload(kSize);
  for (std::size_t i = 0; i < payload.size(); ++i) {
    payload[i] = static_cast<char>((i * 31 + 7) & 0xff);
  }
  {
    std::ofstream out(base / "seed" / "payload.bin", std::ios::binary);
    out.write(payload.data(), static_cast<std::streamsize>(payload.size()));
  }

  std::cout << "selftest: dirs ready" << std::endl;
  lt::file_storage storage;
  storage.add_file("payload.bin", static_cast<std::int64_t>(kSize));
  std::cout << "selftest: storage ready" << std::endl;
  lt::create_torrent creator(storage, 16 * 1024);
  std::cout << "selftest: creator ready" << std::endl;
  creator.set_creator("drift-selftest");
  lt::set_piece_hashes(creator, (base / "seed").string(), ec);
  if (ec) {
    error = "selftest: set_piece_hashes failed: " + ec.message();
    return false;
  }
  auto const entry = creator.generate();
  std::cout << "selftest: entry generated" << std::endl;
  std::vector<char> torrentBytes;
  lt::bencode(std::back_inserter(torrentBytes), entry);
  std::cout << "selftest: bencoded " << torrentBytes.size() << std::endl;
  lt::error_code infoError;
  lt::torrent_info info(lt::span<char const>(torrentBytes.data(),
                                              static_cast<std::ptrdiff_t>(torrentBytes.size())),
                        infoError, lt::from_span);
  if (infoError) {
    error = "selftest: torrent_info failed: " + infoError.message();
    return false;
  }
  std::cout << "selftest: fixture torrent created" << std::endl;
  auto const magnet = lt::make_magnet_uri(info);
  std::cout << "selftest: magnet " << magnet << std::endl;

  std::cout << "selftest: creating fixture" << std::endl;
  lt::settings_pack seedSettings;
  seedSettings.set_str(lt::settings_pack::listen_interfaces,
                       "127.0.0.1:" + std::to_string(freePort()));
  seedSettings.set_bool(lt::settings_pack::enable_dht, false);
  seedSettings.set_bool(lt::settings_pack::enable_lsd, false);
  seedSettings.set_bool(lt::settings_pack::enable_upnp, false);
  seedSettings.set_bool(lt::settings_pack::enable_natpmp, false);
  lt::session seeder{lt::session_params(seedSettings)};

  lt::add_torrent_params seedParams;
  seedParams.ti = std::make_shared<lt::torrent_info>(info);
  seedParams.save_path = (base / "seed").string();
  seedParams.flags |= lt::torrent_flags::seed_mode;
  seedParams.flags &= ~lt::torrent_flags::auto_managed;
  seedParams.flags &= ~lt::torrent_flags::paused;
  auto seedHandle = seeder.add_torrent(std::move(seedParams), ec);
  if (ec) {
    error = "selftest: seed add failed: " + ec.message();
    return false;
  }
  auto const seedPort = seeder.listen_port();
  if (!waitFor(30s, [&] {
        drain(seeder);
        return seedHandle.status().is_seeding;
      })) {
    error = "selftest: seeder did not reach seeding state";
    return false;
  }
  std::cout << "selftest: seeder ready on 127.0.0.1:" << seedPort << std::endl;

  EngineConfig config;
  config.savePath = (base / "download").string();
  Engine engine((base / "state").string(), config);
  if (!engine.init(error)) {
    error = "selftest: engine init failed: " + error;
    return false;
  }
  std::cout << "selftest: engine listening on port " << engine.listenPort() << std::endl;

  AddOptions options;
  options.savePath = (base / "download").string();
  std::string hash;
  if (!engine.addMagnet(magnet, options, hash, error)) {
    error = "selftest: add magnet failed: " + error;
    return false;
  }
  std::cout << "selftest: added magnet " << hash << std::endl;
  if (!engine.connectPeer(hash, "127.0.0.1", static_cast<int>(seedPort))) {
    error = "selftest: connect_peer failed";
    return false;
  }

  bool completed = waitFor(120s, [&] {
    engine.tick();
    drain(seeder);
    return engine.progress(hash) >= 0.999f;
  });
  if (!completed) {
    error = "selftest: download did not complete (progress "
            + std::to_string(engine.progress(hash)) + ")";
    return false;
  }
  std::cout << "selftest: download complete" << std::endl;

  auto const downloaded = base / "download" / "payload.bin";
  std::ifstream in(downloaded, std::ios::binary);
  std::string actual((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
  if (actual.size() != payload.size()
      || !std::equal(payload.begin(), payload.end(), actual.begin())) {
    error = "selftest: downloaded payload differs";
    return false;
  }
  std::cout << "selftest: payload verified (" << actual.size() << " bytes)" << std::endl;

  if (!engine.saveAllResume()) {
    error = "selftest: resume save timed out";
    return false;
  }
  engine.shutdown();
  seeder.pause();

  Engine restored((base / "state").string(), EngineConfig{});
  std::string restoreError;
  if (!restored.init(restoreError)) {
    error = "selftest: restart init failed: " + restoreError;
    return false;
  }
  auto const hashes = restored.hashes();
  auto it = std::find(hashes.begin(), hashes.end(), hash);
  if (it == hashes.end()) {
    error = "selftest: torrent missing after restart";
    return false;
  }
  auto const restoredProgress = restored.progress(hash);
  if (restoredProgress < 0.999f) {
    error = "selftest: progress lost after restart ("
            + std::to_string(restoredProgress) + ")";
    return false;
  }
  std::cout << "selftest: resume restored progress " << restoredProgress << std::endl;
  restored.shutdown();

  fs::remove_all(base, fsEc);
  std::cout << "SELFTEST PASS" << std::endl;
  return true;
}

}  // namespace drift
