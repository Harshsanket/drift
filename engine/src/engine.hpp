// SPDX-License-Identifier: BSD-3-Clause
// Drift engine — session, torrent state and wire protocol handlers.
#pragma once

#include <boost/json.hpp>

#include <libtorrent/session.hpp>
#include <libtorrent/torrent_handle.hpp>

#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

namespace drift {

struct AddOptions {
  std::string savePath;
  bool stopped = false;
  bool sequential = false;
  bool firstLastPiecePriority = false;
  bool autoManaged = true;
  std::string category;
  std::vector<std::string> tags;
};

struct EngineConfig {
  std::string stateDir;
  std::string savePath;
  int listenPort = 0;
  int downloadLimit = 0;
  int uploadLimit = 0;
};

class Engine {
 public:
  using Emit = std::function<void(boost::json::object)>;

  Engine(std::string stateDir, EngineConfig config);
  ~Engine();

  bool init(std::string& error);
  void shutdown();

  void setEmitter(Emit emit) { emit_ = std::move(emit); }
  void tick();

  // Protocol commands. Every handler returns a response object (always with
  // an "op" field); errors carry "ok": false and "message".
  boost::json::object handle(boost::json::object const& request);

  // Used by --selftest (not part of the wire protocol).
  bool addMagnet(std::string const& uri, AddOptions const& options,
                 std::string& hash, std::string& error);
  bool addTorrentFile(std::string const& bytes, AddOptions const& options,
                      std::string& hash, std::string& error);
  bool connectPeer(std::string const& hash, std::string const& address, int port);
  bool saveAllResume();
  std::vector<std::string> hashes() const;
  float progress(std::string const& hash) const;
  int listenPort() const { return session_ ? session_->listen_port() : 0; }
  std::string stateDir() const { return stateDir_; }

 private:
  struct TorrentMeta {
    std::string category;
    std::vector<std::string> tags;
    std::string displayName;
    bool firstLastPiecePriority = false;
  };

  boost::json::object add(boost::json::object const& request);
  boost::json::object remove(boost::json::object const& request);
  boost::json::object startStop(boost::json::object const& request, bool start);
  boost::json::object list();
  boost::json::object details(std::string const& hash);
  boost::json::object exportTorrent(std::string const& hash);
  boost::json::object pieceStates(std::string const& hash);
  boost::json::object limits();
  boost::json::object setLimits(boost::json::object const& request);
  boost::json::object setFlags(boost::json::object const& request);
  boost::json::object recheck(boost::json::object const& request);
  boost::json::object queue(boost::json::object const& request);
  boost::json::object rename(boost::json::object const& request);
  boost::json::object setLocation(boost::json::object const& request);
  boost::json::object setFilePriority(boost::json::object const& request);
  boost::json::object categories();
  boost::json::object createCategory(boost::json::object const& request);
  boost::json::object removeCategories(boost::json::object const& request);
  boost::json::object setCategory(boost::json::object const& request);
  boost::json::object tags();
  boost::json::object createTags(boost::json::object const& request);
  boost::json::object deleteTags(boost::json::object const& request);
  boost::json::object addRemoveTags(boost::json::object const& request, bool add);
  boost::json::object addTrackers(boost::json::object const& request);
  boost::json::object editTracker(boost::json::object const& request);
  boost::json::object removeTrackers(boost::json::object const& request);
  boost::json::object reannounce(boost::json::object const& request);
  boost::json::object addWebSeeds(boost::json::object const& request);
  boost::json::object editWebSeed(boost::json::object const& request);
  boost::json::object removeWebSeeds(boost::json::object const& request);
  boost::json::object banIPs(boost::json::object const& request, bool ban);
  boost::json::object importQbittorrent(boost::json::object const& request);
  boost::json::object stats();

  boost::json::object summary(lt::torrent_handle const& handle) const;
  boost::json::object summaryForHash(std::string const& hash) const;
  boost::json::object detailsFor(lt::torrent_handle const& handle) const;

  void popAlerts();
  void saveResume(lt::torrent_handle const& handle);
  void writeResume(lt::torrent_handle const& handle, lt::add_torrent_params const& atp);
  void loadResumeFiles();
  void broadcastState(bool force);
  void emitLog(std::string const& message);
  void loadConfig();
  void saveConfig() const;
  std::string resumePath(std::string const& hash) const;
  std::string torrentHash(lt::torrent_handle const& handle) const;
  lt::torrent_handle find(std::string const& hash) const;
  void applyAddOptions(lt::add_torrent_params& atp, AddOptions const& options) const;
  std::string effectiveSavePath(AddOptions const& options) const;
  void applyIPFilter();
  void applyFirstLastPiecePriority(lt::torrent_handle const& handle, bool enabled);
  static std::vector<std::string> idsFrom(boost::json::object const& request);
  static std::vector<std::string> stringsFrom(boost::json::object const& request, char const* key);

  std::string stateDir_;
  EngineConfig config_;
  Emit emit_;

  std::unique_ptr<lt::session> session_;
  std::map<std::string, lt::torrent_handle> torrents_;
  std::map<std::string, TorrentMeta> meta_;
  std::map<std::string, std::string> categoryPaths_;
  std::vector<std::string> knownTags_;
  std::vector<std::string> bannedIPs_;
  std::map<std::string, std::string> lastSummary_;
  std::map<std::string, std::int64_t> resumeRequestedAt_;
  bool configDirty_ = false;
  std::uint64_t rid_ = 0;
  bool initialized_ = false;
};

}  // namespace drift
