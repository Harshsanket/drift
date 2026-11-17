#include "engine.hpp"

#include "base64.hpp"

#include <boost/json.hpp>

#include <libtorrent/alert_types.hpp>
#include <libtorrent/announce_entry.hpp>
#include <libtorrent/bdecode.hpp>
#include <libtorrent/magnet_uri.hpp>
#include <libtorrent/peer_info.hpp>
#include <libtorrent/read_resume_data.hpp>
#include <libtorrent/settings_pack.hpp>
#include <libtorrent/torrent_info.hpp>
#include <libtorrent/version.hpp>
#include <libtorrent/write_resume_data.hpp>

#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <ctime>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <set>
#include <sstream>
#include <thread>

namespace drift {
namespace {

namespace fs = std::filesystem;
using namespace std::chrono_literals;

std::string nowStamp() {
  auto const now = std::chrono::system_clock::now();
  auto const tt = std::chrono::system_clock::to_time_t(now);
  std::tm tm{};
  gmtime_r(&tt, &tm);
  char buffer[32];
  std::strftime(buffer, sizeof(buffer), "%Y-%m-%dT%H:%M:%SZ", &tm);
  return buffer;
}

std::string expandHome(std::string path) {
  if (path.rfind("~/", 0) == 0) {
    char const* home = std::getenv("HOME");
    if (home != nullptr) return std::string(home) + path.substr(1);
  }
  return path;
}

int pickFreePort() {
  // Ephemeral listen port by default (D20: coexist with a local qBittorrent).
  int fd = ::socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) return 0;
  sockaddr_in addr{};
  addr.sin_family = AF_INET;
  addr.sin_addr.s_addr = htonl(INADDR_ANY);
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

std::int64_t unixNow() {
  return std::chrono::duration_cast<std::chrono::seconds>(
             std::chrono::system_clock::now().time_since_epoch())
      .count();
}

std::string prioName(int priority) {
  switch (priority) {
    case 0: return "ignored";
    case 6: return "high";
    case 7: return "maximum";
    default: return "normal";
  }
}

// qBittorrent exposes 0/1/6/7 while libtorrent uses 0..7 (4 = default).
int apiPriority(lt::download_priority_t priority) {
  auto const value = static_cast<std::uint8_t>(priority);
  if (value == 0) return 0;
  if (value <= static_cast<std::uint8_t>(lt::default_priority)) return 1;
  if (value <= 6) return 6;
  return 7;
}

boost::json::object errorResponse(std::string const& op, std::string const& message) {
  boost::json::object out;
  out["op"] = op;
  out["ok"] = false;
  out["message"] = message;
  return out;
}

}  // namespace

Engine::Engine(std::string stateDir, EngineConfig config)
    : stateDir_(std::move(stateDir)), config_(std::move(config)) {
  config_.stateDir = stateDir_;
}

Engine::~Engine() {
  if (session_) session_.reset();
}

bool Engine::init(std::string& error) {
  std::error_code ec;
  fs::create_directories(stateDir_, ec);
  if (ec) {
    error = "cannot create state dir: " + ec.message();
    return false;
  }
  fs::create_directories(fs::path(stateDir_) / "resume", ec);
  if (ec) {
    error = "cannot create resume dir: " + ec.message();
    return false;
  }

  loadConfig();
  int port = config_.listenPort;
  if (port == 0) port = pickFreePort();

  lt::settings_pack settings;
  settings.set_str(lt::settings_pack::listen_interfaces, "0.0.0.0:" + std::to_string(port));
  settings.set_int(lt::settings_pack::alert_mask,
                   static_cast<std::uint32_t>(lt::alert_category::error
                                              | lt::alert_category::storage
                                              | lt::alert_category::status));
  settings.set_bool(lt::settings_pack::enable_dht, true);
  settings.set_bool(lt::settings_pack::enable_lsd, true);
  settings.set_bool(lt::settings_pack::enable_upnp, false);
  settings.set_bool(lt::settings_pack::enable_natpmp, false);
  settings.set_bool(lt::settings_pack::allow_multiple_connections_per_ip, true);
  settings.set_int(lt::settings_pack::download_rate_limit, config_.downloadLimit);
  settings.set_int(lt::settings_pack::upload_rate_limit, config_.uploadLimit);
  settings.set_str(lt::settings_pack::user_agent,
                   "Drift/0.1 libtorrent/" LIBTORRENT_VERSION);

  lt::session_params params(settings);
  session_ = std::make_unique<lt::session>(params);
  config_.listenPort = session_->listen_port();
  if (config_.savePath.empty()) {
    char const* home = std::getenv("HOME");
    config_.savePath = home != nullptr ? std::string(home) + "/Downloads" : ".";
  }
  config_.savePath = expandHome(config_.savePath);
  fs::create_directories(config_.savePath, ec);

  applyIPFilter();
  loadResumeFiles();
  initialized_ = true;
  saveConfig();
  emitLog("engine started libtorrent=" LIBTORRENT_VERSION
          " listen=" + std::to_string(config_.listenPort)
          + " state=" + stateDir_);
  return true;
}

void Engine::loadConfig() {
  auto path = fs::path(stateDir_) / "session.conf";
  std::ifstream in(path);
  if (!in) return;
  std::stringstream buffer;
  buffer << in.rdbuf();
  boost::system::error_code ec;
  auto value = boost::json::parse(buffer.str(), ec);
  if (ec || !value.is_object()) {
    emitLog("session.conf unreadable; using defaults");
    return;
  }
  auto const& obj = value.as_object();
  if (auto const* savePath = obj.if_contains("savePath"); savePath && savePath->is_string()) {
    config_.savePath = savePath->as_string().c_str();
  }
  if (config_.listenPort == 0) {
    if (auto const* port = obj.if_contains("listenPort"); port && port->is_int64()) {
      config_.listenPort = static_cast<int>(port->as_int64());
    }
  }
  if (auto const* limit = obj.if_contains("downloadLimit"); limit && limit->is_int64()) {
    config_.downloadLimit = static_cast<int>(limit->as_int64());
  }
  if (auto const* limit = obj.if_contains("uploadLimit"); limit && limit->is_int64()) {
    config_.uploadLimit = static_cast<int>(limit->as_int64());
  }
  if (auto const* categories = obj.if_contains("categories"); categories && categories->is_array()) {
    for (auto const& entry : categories->as_array()) {
      if (!entry.is_object()) continue;
      auto const& c = entry.as_object();
      auto const* name = c.if_contains("name");
      auto const* savePath = c.if_contains("savePath");
      if (name && name->is_string()) {
        categoryPaths_[name->as_string().c_str()] =
            (savePath && savePath->is_string()) ? savePath->as_string().c_str() : "";
      }
    }
  }
  if (auto const* tags = obj.if_contains("tags"); tags && tags->is_array()) {
    for (auto const& tag : tags->as_array()) {
      if (tag.is_string()) knownTags_.push_back(tag.as_string().c_str());
    }
  }
  if (auto const* bans = obj.if_contains("bannedIPs"); bans && bans->is_array()) {
    for (auto const& ip : bans->as_array()) {
      if (ip.is_string()) bannedIPs_.push_back(ip.as_string().c_str());
    }
  }
  if (auto const* torrents = obj.if_contains("torrents"); torrents && torrents->is_object()) {
    for (auto const& [hash, entry] : torrents->as_object()) {
      if (!entry.is_object()) continue;
      TorrentMeta meta;
      auto const& m = entry.as_object();
      if (auto const* category = m.if_contains("category"); category && category->is_string()) {
        meta.category = category->as_string().c_str();
      }
      if (auto const* tags = m.if_contains("tags"); tags && tags->is_array()) {
        for (auto const& tag : tags->as_array()) {
          if (tag.is_string()) meta.tags.push_back(tag.as_string().c_str());
        }
      }
      if (auto const* name = m.if_contains("displayName"); name && name->is_string()) {
        meta.displayName = name->as_string().c_str();
      }
      if (auto const* firstLast = m.if_contains("firstLastPiecePriority");
          firstLast && firstLast->is_bool()) {
        meta.firstLastPiecePriority = firstLast->as_bool();
      }
      meta_[std::string(hash)] = std::move(meta);
    }
  }
}

void Engine::saveConfig() const {
  boost::json::object obj;
  obj["savePath"] = config_.savePath;
  obj["listenPort"] = config_.listenPort;
  obj["downloadLimit"] = config_.downloadLimit;
  obj["uploadLimit"] = config_.uploadLimit;
  boost::json::array categories;
  for (auto const& [name, savePath] : categoryPaths_) {
    boost::json::object entry;
    entry["name"] = name;
    entry["savePath"] = savePath;
    categories.push_back(std::move(entry));
  }
  obj["categories"] = std::move(categories);
  boost::json::array tags;
  for (auto const& tag : knownTags_) tags.push_back(boost::json::value(tag));
  obj["tags"] = std::move(tags);
  boost::json::array bans;
  for (auto const& ip : bannedIPs_) bans.push_back(boost::json::value(ip));
  obj["bannedIPs"] = std::move(bans);

  boost::json::object torrents;
  for (auto const& [hash, meta] : meta_) {
    boost::json::object entry;
    if (!meta.category.empty()) entry["category"] = meta.category;
    if (!meta.displayName.empty()) entry["displayName"] = meta.displayName;
    if (meta.firstLastPiecePriority) entry["firstLastPiecePriority"] = true;
    boost::json::array tags;
    for (auto const& tag : meta.tags) tags.push_back(boost::json::value(tag));
    entry["tags"] = std::move(tags);
    torrents[hash] = std::move(entry);
  }
  obj["torrents"] = std::move(torrents);

  auto path = fs::path(stateDir_) / "session.conf";
  auto tmp = fs::path(stateDir_) / "session.conf.tmp";
  std::ofstream out(tmp, std::ios::trunc);
  if (!out) return;
  out << boost::json::serialize(obj) << "\n";
  out.close();
  std::error_code ec;
  fs::rename(tmp, path, ec);
}

void Engine::emitLog(std::string const& message) {
  auto line = "[" + nowStamp() + "] " + message + "\n";
  std::ofstream out(fs::path(stateDir_) / "engine.log", std::ios::app);
  if (out) out << line;
  if (emit_) {
    boost::json::object event;
    event["op"] = "log";
    event["message"] = message;
    emit_(std::move(event));
  }
}

std::string Engine::resumePath(std::string const& hash) const {
  return (fs::path(stateDir_) / "resume" / (hash + ".fastresume")).string();
}

std::string Engine::torrentHash(lt::torrent_handle const& handle) const {
  return hashHex(handle.info_hashes().get_best());
}

lt::torrent_handle Engine::find(std::string const& hash) const {
  auto it = torrents_.find(hash);
  if (it != torrents_.end()) return it->second;
  return {};
}

void Engine::loadResumeFiles() {
  std::error_code ec;
  auto dir = fs::path(stateDir_) / "resume";
  if (!fs::is_directory(dir, ec)) return;
  for (auto const& entry : fs::directory_iterator(dir, ec)) {
    if (!entry.is_regular_file()) continue;
    if (entry.path().extension() != ".fastresume") continue;
    std::ifstream in(entry.path(), std::ios::binary);
    if (!in) continue;
    std::string bytes((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
    if (bytes.empty()) continue;
    lt::error_code ec2;
    auto atp = lt::read_resume_data(
        lt::span<char const>(bytes.data(), static_cast<std::ptrdiff_t>(bytes.size())), ec2);
    if (ec2) {
      emitLog("resume load failed " + entry.path().filename().string() + ": " + ec2.message());
      continue;
    }
    if (atp.save_path.empty()) atp.save_path = config_.savePath;
    auto handle = session_->add_torrent(std::move(atp), ec2);
    if (ec2) {
      emitLog("resume add failed " + entry.path().filename().string() + ": " + ec2.message());
      continue;
    }
    auto hash = torrentHash(handle);
    torrents_[hash] = handle;
  }
  if (!torrents_.empty()) {
    emitLog("restored " + std::to_string(torrents_.size()) + " torrent(s) from resume data");
  }
}

void Engine::applyAddOptions(lt::add_torrent_params& atp, AddOptions const& options) const {
  atp.save_path = effectiveSavePath(options);
  if (options.stopped) {
    atp.flags |= lt::torrent_flags::paused;
    atp.flags &= ~lt::torrent_flags::auto_managed;
  }
  if (options.sequential) atp.flags |= lt::torrent_flags::sequential_download;
  if (options.autoManaged && !options.stopped) atp.flags |= lt::torrent_flags::auto_managed;
  else if (!options.stopped) atp.flags &= ~lt::torrent_flags::auto_managed;
  if (options.firstLastPiecePriority) {
    // libtorrent has no first/last flag; piece selection happens after add.
  }
}

std::string Engine::effectiveSavePath(AddOptions const& options) const {
  auto path = options.savePath.empty() ? config_.savePath : expandHome(options.savePath);
  return path;
}

bool Engine::addMagnet(std::string const& uri, AddOptions const& options,
                       std::string& hash, std::string& error) {
  lt::error_code ec;
  auto atp = lt::parse_magnet_uri(uri, ec);
  if (ec) {
    error = "invalid magnet: " + ec.message();
    return false;
  }
  applyAddOptions(atp, options);
  auto handle = session_->add_torrent(std::move(atp), ec);
  if (ec) {
    error = "add failed: " + ec.message();
    return false;
  }
  hash = torrentHash(handle);
  torrents_[hash] = handle;
  auto& meta = meta_[hash];
  if (!options.category.empty()) meta.category = options.category;
  for (auto const& tag : options.tags) {
    if (std::find(meta.tags.begin(), meta.tags.end(), tag) == meta.tags.end()) {
      meta.tags.push_back(tag);
    }
  }
  if (options.firstLastPiecePriority) {
    meta.firstLastPiecePriority = true;
    applyFirstLastPiecePriority(handle, true);
  }
  if (!options.category.empty() || !options.tags.empty() || options.firstLastPiecePriority) {
    configDirty_ = true;
  }
  saveResume(handle);
  emitLog("add " + hash + " " + (options.stopped ? "paused" : "started"));
  return true;
}

bool Engine::addTorrentFile(std::string const& bytes, AddOptions const& options,
                            std::string& hash, std::string& error) {
  lt::error_code ec;
  lt::torrent_info info(lt::span<char const>(bytes.data(),
                                             static_cast<std::ptrdiff_t>(bytes.size())),
                        ec, lt::from_span);
  if (ec) {
    error = "invalid torrent file: " + ec.message();
    return false;
  }
  lt::add_torrent_params atp;
  atp.ti = std::make_shared<lt::torrent_info>(info);
  applyAddOptions(atp, options);
  auto handle = session_->add_torrent(std::move(atp), ec);
  if (ec) {
    error = "add failed: " + ec.message();
    return false;
  }
  hash = torrentHash(handle);
  torrents_[hash] = handle;
  auto& meta = meta_[hash];
  if (!options.category.empty()) meta.category = options.category;
  for (auto const& tag : options.tags) {
    if (std::find(meta.tags.begin(), meta.tags.end(), tag) == meta.tags.end()) {
      meta.tags.push_back(tag);
    }
  }
  if (options.firstLastPiecePriority) {
    meta.firstLastPiecePriority = true;
    applyFirstLastPiecePriority(handle, true);
  }
  if (!options.category.empty() || !options.tags.empty() || options.firstLastPiecePriority) {
    configDirty_ = true;
  }
  saveResume(handle);
  emitLog("add " + hash + " file");
  return true;
}

bool Engine::connectPeer(std::string const& hash, std::string const& address, int port) {
  auto handle = find(hash);
  if (!handle.is_valid()) return false;
  lt::error_code ec;
  auto addr = lt::make_address(address, ec);
  if (ec) return false;
  handle.connect_peer(lt::tcp::endpoint(addr, static_cast<std::uint16_t>(port)));
  return true;
}

bool Engine::saveAllResume() {
  if (!session_) return false;
  std::size_t pending = 0;
  for (auto const& [hash, handle] : torrents_) {
    (void)hash;
    if (!handle.is_valid()) continue;
    handle.save_resume_data(lt::torrent_handle::save_info_dict);
    ++pending;
  }
  auto deadline = std::chrono::steady_clock::now() + 5s;
  while (pending > 0 && std::chrono::steady_clock::now() < deadline) {
    std::vector<lt::alert*> alerts;
    session_->pop_alerts(&alerts);
    for (auto* alert : alerts) {
      if (auto* saved = lt::alert_cast<lt::save_resume_data_alert>(alert)) {
        writeResume(saved->handle, saved->params);
        if (pending > 0) --pending;
      } else if (auto* failed = lt::alert_cast<lt::save_resume_data_failed_alert>(alert)) {
        emitLog("resume save failed " + torrentHash(failed->handle) + ": " + failed->message());
        if (pending > 0) --pending;
      }
    }
    if (pending > 0) std::this_thread::sleep_for(50ms);
  }
  saveConfig();
  return pending == 0;
}

void Engine::saveResume(lt::torrent_handle const& handle) {
  if (!handle.is_valid()) return;
  handle.save_resume_data(lt::torrent_handle::save_info_dict);
}

void Engine::writeResume(lt::torrent_handle const& handle, lt::add_torrent_params const& atp) {
  auto bytes = lt::write_resume_data_buf(atp);
  auto hash = torrentHash(handle);
  if (hash.empty() || hash == std::string(40, '0')) {
    hash = hashHex(atp.info_hashes.get_best());
  }
  auto path = resumePath(hash);
  auto tmp = path + ".tmp";
  std::ofstream out(tmp, std::ios::binary | std::ios::trunc);
  if (!out) {
    emitLog("cannot write resume " + hash);
    return;
  }
  out.write(bytes.data(), static_cast<std::streamsize>(bytes.size()));
  out.close();
  std::error_code ec;
  fs::rename(tmp, path, ec);
  if (ec) emitLog("resume rename failed " + hash + ": " + ec.message());
}

void Engine::popAlerts() {
  std::vector<lt::alert*> alerts;
  session_->pop_alerts(&alerts);
  for (auto* alert : alerts) {
    if (auto* saved = lt::alert_cast<lt::save_resume_data_alert>(alert)) {
      writeResume(saved->handle, saved->params);
      continue;
    }
    if (auto* failed = lt::alert_cast<lt::save_resume_data_failed_alert>(alert)) {
      emitLog("resume save failed " + torrentHash(failed->handle) + ": " + failed->message());
      continue;
    }
    if (auto* error = lt::alert_cast<lt::torrent_error_alert>(alert)) {
      emitLog("torrent error " + torrentHash(error->handle) + ": " + error->message());
      if (emit_) {
        boost::json::object event;
        event["op"] = "alert";
        event["level"] = "error";
        event["id"] = torrentHash(error->handle);
        event["message"] = error->message();
        emit_(std::move(event));
      }
      continue;
    }
    if (auto* metadata = lt::alert_cast<lt::metadata_received_alert>(alert)) {
      auto hash = torrentHash(metadata->handle);
      emitLog("metadata received " + hash);
      auto metaIt = meta_.find(hash);
      if (metaIt != meta_.end() && metaIt->second.firstLastPiecePriority) {
        applyFirstLastPiecePriority(metadata->handle, true);
      }
      saveResume(metadata->handle);
      continue;
    }
    if (auto* listen = lt::alert_cast<lt::listen_succeeded_alert>(alert)) {
      emitLog("listen " + listen->address.to_string() + ":" + std::to_string(listen->port));
      continue;
    }
    if (auto* listen = lt::alert_cast<lt::listen_failed_alert>(alert)) {
      emitLog("listen failed: " + listen->message());
      continue;
    }
    if (alert->category() & lt::alert_category::error) {
      emitLog("alert: " + alert->message());
    }
  }
}

void Engine::tick() {
  if (!session_) return;
  popAlerts();
  auto const now = unixNow();

  for (auto& [hash, handle] : torrents_) {
    if (!handle.is_valid()) continue;
    auto& requested = resumeRequestedAt_[hash];
    auto const status = handle.status(lt::torrent_handle::query_name
                                      | lt::torrent_handle::query_save_path);
    if (now - requested >= 30 && status.need_save_resume_data) {
      saveResume(handle);
      requested = now;
    }
  }
  for (auto it = torrents_.begin(); it != torrents_.end();) {
    if (!it->second.is_valid()) it = torrents_.erase(it);
    else ++it;
  }
  broadcastState(false);
}

void Engine::broadcastState(bool force) {
  boost::json::object current;
  std::map<std::string, std::string> currentText;
  for (auto const& [hash, handle] : torrents_) {
    if (!handle.is_valid()) continue;
    auto object = summary(handle);
    currentText[hash] = boost::json::serialize(object);
    current[hash] = std::move(object);
  }

  boost::json::object changed;
  boost::json::array removed;
  for (auto const& [hash, text] : currentText) {
    auto it = lastSummary_.find(hash);
    if (force || it == lastSummary_.end() || it->second != text) {
      changed[hash] = current[hash];
    }
  }
  for (auto const& [hash, text] : lastSummary_) {
    (void)text;
    if (currentText.find(hash) == currentText.end()) removed.push_back(boost::json::value(hash));
  }
  lastSummary_ = std::move(currentText);
  for (auto const& hash : removed) {
    resumeRequestedAt_.erase(hash.as_string().c_str());
  }
  if (!force && changed.empty() && removed.empty()) return;
  if (!emit_) return;
  boost::json::object event;
  event["op"] = "state";
  event["rid"] = static_cast<std::int64_t>(++rid_);
  event["torrents"] = std::move(changed);
  if (!removed.empty()) event["torrents_removed"] = std::move(removed);
  event["stats"] = stats();
  emit_(std::move(event));
}

boost::json::object Engine::summary(lt::torrent_handle const& handle) const {
  auto const status = handle.status(lt::torrent_handle::query_name
                                    | lt::torrent_handle::query_save_path
                                    | lt::torrent_handle::query_accurate_download_counters);
  boost::json::object out;
  auto const hash = torrentHash(handle);
  out["id"] = hash;
  auto metaIt = meta_.find(hash);
  out["name"] = (metaIt != meta_.end() && !metaIt->second.displayName.empty())
                    ? metaIt->second.displayName
                    : status.name;
  out["progress"] = static_cast<double>(status.progress);
  out["size"] = status.total;
  out["downloadSpeed"] = status.download_payload_rate;
  out["uploadSpeed"] = status.upload_payload_rate;
  auto const remaining = status.total_wanted > status.total_wanted_done
                             ? status.total_wanted - status.total_wanted_done
                             : 0;
  if (status.download_payload_rate > 0 && remaining > 0) {
    out["eta"] = static_cast<double>(remaining) / status.download_payload_rate;
  } else {
    out["eta"] = nullptr;
  }
  out["timeActive"] = static_cast<std::int64_t>(status.active_duration.count());
  out["ratio"] = status.all_time_download > 0
                     ? static_cast<double>(status.all_time_upload)
                           / static_cast<double>(status.all_time_download)
                     : 0.0;
  out["seeds"] = status.num_seeds;
  out["peers"] = status.num_peers;
  out["availability"] = static_cast<double>(status.distributed_copies);
  out["downloaded"] = status.all_time_download;
  out["uploaded"] = status.all_time_upload;
  out["savePath"] = status.save_path;
  out["addedOn"] = static_cast<std::int64_t>(status.added_time);
  out["sequential"] = bool(status.flags & lt::torrent_flags::sequential_download);
  out["firstLastPiecePriority"] =
      metaIt != meta_.end() && metaIt->second.firstLastPiecePriority;
  out["superSeeding"] = bool(status.flags & lt::torrent_flags::super_seeding);
  out["autoManaged"] = bool(status.flags & lt::torrent_flags::auto_managed);

  std::string state;
  if (status.errc) {
    state = "error";
  } else if (status.flags & lt::torrent_flags::paused) {
    state = "stopped";
  } else if (status.moving_storage) {
    state = "moving";
  } else {
    switch (status.state) {
      case lt::torrent_status::checking_files:
      case lt::torrent_status::checking_resume_data:
        state = "checking";
        break;
      case lt::torrent_status::downloading_metadata:
        state = "downloading";
        break;
      case lt::torrent_status::downloading:
        state = (status.download_payload_rate == 0 && status.num_peers == 0)
                    ? "stalled"
                    : "downloading";
        break;
      case lt::torrent_status::finished:
        state = "completed";
        break;
      case lt::torrent_status::seeding:
        state = "seeding";
        break;
      default:
        state = "queued";
        break;
    }
  }
  out["status"] = state;
  if (metaIt != meta_.end() && !metaIt->second.category.empty()) {
    out["category"] = metaIt->second.category;
  } else {
    out["category"] = nullptr;
  }
  boost::json::array tags;
  if (metaIt != meta_.end()) {
    for (auto const& tag : metaIt->second.tags) tags.push_back(boost::json::value(tag));
  }
  out["tags"] = std::move(tags);
  return out;
}

boost::json::object Engine::summaryForHash(std::string const& hash) const {
  auto handle = find(hash);
  if (!handle.is_valid()) return {};
  return summary(handle);
}

boost::json::object Engine::detailsFor(lt::torrent_handle const& handle) const {
  auto const status = handle.status();
  auto const hash = torrentHash(handle);
  boost::json::object general;
  general["hash"] = hash;
  general["savePath"] = status.save_path;
  general["addedOn"] = static_cast<std::int64_t>(status.added_time);
  if (status.completed_time > 0) general["completedOn"] = static_cast<std::int64_t>(status.completed_time);
  else general["completedOn"] = nullptr;
  general["downloaded"] = status.all_time_download;
  general["uploaded"] = status.all_time_upload;
  general["wasted"] = status.total_failed_bytes + status.total_redundant_bytes;
  general["connections"] = status.num_peers;
  general["piecesTotal"] = 0;
  general["piecesHave"] = status.num_pieces;
  general["comment"] = "";
  general["createdBy"] = "";
  general["createdOn"] = nullptr;

  boost::json::array trackers;
  boost::json::array peers;
  boost::json::array webSeeds;
  boost::json::array files;

  if (status.has_metadata) {
    auto const info = handle.torrent_file();
    if (info) {
      general["piecesTotal"] = info->num_pieces();
      general["comment"] = std::string(info->comment());
      general["createdBy"] = std::string(info->creator());
      if (info->creation_date() > 0) {
        general["createdOn"] = static_cast<std::int64_t>(info->creation_date());
      }
      auto const& storage = info->files();
      std::vector<std::int64_t> progress;
      try {
        progress = handle.file_progress();
      } catch (...) {
        progress.clear();
      }
      for (lt::file_index_t i{0}; static_cast<int>(i) < storage.num_files(); ++i) {
        auto const index = static_cast<int>(i);
        boost::json::object file;
        file["name"] = storage.file_path(i);
        file["size"] = storage.file_size(i);
        auto const done = index < static_cast<int>(progress.size()) ? progress[index] : 0;
        auto const size = storage.file_size(i);
        file["progress"] = size > 0 ? static_cast<double>(done) / static_cast<double>(size) : 0.0;
        file["priority"] = apiPriority(handle.file_priority(i));
        files.push_back(std::move(file));
      }
      for (auto const& url : handle.url_seeds()) {
        boost::json::object webSeed;
        webSeed["url"] = url;
        webSeeds.push_back(std::move(webSeed));
      }
      for (auto const& url : handle.http_seeds()) {
        boost::json::object webSeed;
        webSeed["url"] = url;
        webSeeds.push_back(std::move(webSeed));
      }
    }
  }

  for (auto const& tracker : handle.trackers()) {
    boost::json::object row;
    row["url"] = tracker.url;
    bool updating = false;
    int fails = 0;
    int complete = -1;
    int incomplete = -1;
    int downloaded = -1;
    for (auto const& endpoint : tracker.endpoints) {
      for (auto const& ih : endpoint.info_hashes) {
        updating = updating || ih.updating;
        fails = std::max(fails, static_cast<int>(ih.fails));
        if (ih.scrape_complete >= 0) complete = std::max(complete, ih.scrape_complete);
        if (ih.scrape_incomplete >= 0) incomplete = std::max(incomplete, ih.scrape_incomplete);
        if (ih.scrape_downloaded >= 0) downloaded = std::max(downloaded, ih.scrape_downloaded);
      }
    }
    row["status"] = updating ? "Updating"
                             : (fails > 0 ? "Not working"
                                          : (tracker.verified ? "Working" : "Not contacted"));
    row["peers"] = std::max(0, complete + incomplete);
    row["seeds"] = std::max(0, complete);
    row["leeches"] = std::max(0, incomplete);
    row["downloaded"] = std::max(0, downloaded);
    trackers.push_back(std::move(row));
  }

  try {
    std::vector<lt::peer_info> peerInfos;
    handle.get_peer_info(peerInfos);
    for (auto const& peer : peerInfos) {
      boost::json::object row;
      auto endpoint = peer.remote_endpoint();
      row["ip"] = endpoint.address().to_string();
      row["port"] = endpoint.port();
      row["client"] = peer.client;
      std::string flags;
      if (peer.flags & lt::peer_info::seed) flags += "S";
      if (peer.flags & lt::peer_info::utp_socket) flags += "P";
      if (peer.flags & lt::peer_info::rc4_encrypted) flags += "E";
      if (peer.flags & lt::peer_info::plaintext_encrypted) flags += "E";
      if (peer.flags & lt::peer_info::upload_only) flags += "U";
      if (flags.empty()) flags = "-";
      row["flags"] = flags;
      if (peer.connection_type & lt::peer_info::web_seed) row["connection"] = "Web seed";
      else if (peer.flags & lt::peer_info::utp_socket) row["connection"] = "μTP";
      else row["connection"] = "TCP";
      row["progress"] = static_cast<double>(peer.progress);
      row["downSpeed"] = peer.payload_down_speed;
      row["upSpeed"] = peer.payload_up_speed;
      row["country"] = "";
      row["countryCode"] = "";
      row["downloaded"] = peer.total_download;
      row["uploaded"] = peer.total_upload;
      peers.push_back(std::move(row));
    }
  } catch (...) {
    // Peer list is best-effort while a torrent is checking or paused.
  }

  boost::json::object out;
  out["general"] = std::move(general);
  out["trackers"] = std::move(trackers);
  out["peers"] = std::move(peers);
  out["webSeeds"] = std::move(webSeeds);
  out["files"] = std::move(files);
  return out;
}

boost::json::object Engine::add(boost::json::object const& request) {
  AddOptions options;
  if (auto const* raw = request.if_contains("options"); raw && raw->is_object()) {
    auto const& obj = raw->as_object();
    if (auto const* value = obj.if_contains("savePath"); value && value->is_string()) {
      options.savePath = value->as_string().c_str();
    }
    if (auto const* value = obj.if_contains("stopped"); value && value->is_bool()) {
      options.stopped = value->as_bool();
    }
    if (auto const* value = obj.if_contains("sequential"); value && value->is_bool()) {
      options.sequential = value->as_bool();
    }
    if (auto const* value = obj.if_contains("firstLastPiecePriority"); value && value->is_bool()) {
      options.firstLastPiecePriority = value->as_bool();
    }
    if (auto const* value = obj.if_contains("autoManaged"); value && value->is_bool()) {
      options.autoManaged = value->as_bool();
    }
    if (auto const* value = obj.if_contains("category"); value && value->is_string()) {
      options.category = value->as_string().c_str();
    }
    if (auto const* value = obj.if_contains("tags"); value && value->is_array()) {
      for (auto const& tag : value->as_array()) {
        if (tag.is_string()) options.tags.push_back(tag.as_string().c_str());
      }
    }
  }

  std::string hash;
  std::string error;
  bool ok = false;
  if (auto const* magnet = request.if_contains("magnet"); magnet && magnet->is_string()) {
    ok = addMagnet(magnet->as_string().c_str(), options, hash, error);
  } else if (auto const* source = request.if_contains("source"); source && source->is_string()) {
    ok = addMagnet(source->as_string().c_str(), options, hash, error);
  } else if (auto const* torrent = request.if_contains("torrent"); torrent && torrent->is_string()) {
    auto bytes = base64Decode(torrent->as_string().c_str());
    ok = addTorrentFile(bytes, options, hash, error);
  } else {
    error = "missing magnet or torrent";
  }
  if (!ok) return errorResponse("add", error);
  boost::json::object out;
  out["op"] = "add";
  out["ok"] = true;
  out["id"] = hash;
  return out;
}

boost::json::object Engine::remove(boost::json::object const& request) {
  std::vector<std::string> ids;
  if (auto const* id = request.if_contains("id"); id && id->is_string()) {
    ids.push_back(id->as_string().c_str());
  }
  if (auto const* list = request.if_contains("ids"); list && list->is_array()) {
    for (auto const& id : list->as_array()) {
      if (id.is_string()) ids.push_back(id.as_string().c_str());
    }
  }
  bool deleteFiles = false;
  if (auto const* value = request.if_contains("deleteFiles"); value && value->is_bool()) {
    deleteFiles = value->as_bool();
  }
  boost::json::array removed;
  for (auto const& id : ids) {
    auto it = torrents_.find(id);
    if (it == torrents_.end()) continue;
    if (it->second.is_valid()) {
      session_->remove_torrent(it->second,
                               deleteFiles ? lt::session::delete_files
                                           : lt::remove_flags_t{});
    }
    torrents_.erase(it);
    meta_.erase(id);
    lastSummary_.erase(id);
    resumeRequestedAt_.erase(id);
    std::error_code ec;
    fs::remove(resumePath(id), ec);
    removed.push_back(boost::json::value(id));
    emitLog("remove " + id + (deleteFiles ? " (files)" : ""));
  }
  configDirty_ = true;
  broadcastState(false);
  boost::json::object out;
  out["op"] = "remove";
  out["ok"] = true;
  out["removed"] = std::move(removed);
  return out;
}

boost::json::object Engine::startStop(boost::json::object const& request, bool start) {
  std::vector<std::string> ids;
  if (auto const* id = request.if_contains("id"); id && id->is_string()) {
    ids.push_back(id->as_string().c_str());
  }
  if (auto const* list = request.if_contains("ids"); list && list->is_array()) {
    for (auto const& id : list->as_array()) {
      if (id.is_string()) ids.push_back(id.as_string().c_str());
    }
  }
  boost::json::array changed;
  for (auto const& id : ids) {
    auto handle = find(id);
    if (!handle.is_valid()) continue;
    if (start) handle.resume();
    else handle.pause();
    changed.push_back(boost::json::value(id));
    saveResume(handle);
  }
  broadcastState(false);
  boost::json::object out;
  out["op"] = start ? "start" : "stop";
  out["ok"] = true;
  out["ids"] = std::move(changed);
  return out;
}

boost::json::object Engine::list() {
  boost::json::object torrents;
  for (auto const& [hash, handle] : torrents_) {
    if (handle.is_valid()) torrents[hash] = summary(handle);
  }
  boost::json::object out;
  out["op"] = "list";
  out["ok"] = true;
  out["full_update"] = true;
  out["rid"] = static_cast<std::int64_t>(++rid_);
  out["torrents"] = std::move(torrents);
  auto categoryResponse = categories();
  out["categories"] = categoryResponse["categories"];
  auto tagResponse = tags();
  out["tags"] = tagResponse["tags"];
  out["stats"] = stats();
  return out;
}

boost::json::object Engine::details(std::string const& hash) {
  auto handle = find(hash);
  if (!handle.is_valid()) return errorResponse("details", "unknown torrent");
  boost::json::object out;
  out["op"] = "details";
  out["ok"] = true;
  out["torrent"] = detailsFor(handle);
  return out;
}

boost::json::object Engine::exportTorrent(std::string const& hash) {
  auto handle = find(hash);
  if (!handle.is_valid()) return errorResponse("export_torrent", "unknown torrent");
  auto const info = handle.torrent_file();
  if (!info) return errorResponse("export_torrent", "metadata not available");
  auto const metadata = info->metadata();
  auto const size = info->metadata_size();
  if (!metadata || size <= 0) return errorResponse("export_torrent", "metadata not available");
  std::string torrent = "d4:info";
  torrent.append(metadata.get(), static_cast<std::size_t>(size));
  torrent.push_back('e');
  boost::json::object out;
  out["op"] = "export_torrent";
  out["ok"] = true;
  out["data"] = hexEncode(torrent.data(), torrent.size());
  return out;
}

boost::json::object Engine::pieceStates(std::string const& hash) {
  auto handle = find(hash);
  if (!handle.is_valid()) return errorResponse("piece_states", "unknown torrent");
  auto const status = handle.status();
  boost::json::array states;
  states.reserve(status.pieces.size());
  for (int i = 0; i < status.pieces.size(); ++i) {
    states.push_back(boost::json::value(status.pieces.get_bit(lt::piece_index_t{i}) ? 1 : 0));
  }
  boost::json::object out;
  out["op"] = "piece_states";
  out["ok"] = true;
  out["states"] = std::move(states);
  return out;
}

boost::json::object Engine::limits() {
  boost::json::object out;
  out["op"] = "limits";
  out["ok"] = true;
  out["download"] = config_.downloadLimit;
  out["upload"] = config_.uploadLimit;
  return out;
}

boost::json::object Engine::setLimits(boost::json::object const& request) {
  lt::settings_pack pack;
  if (auto const* value = request.if_contains("download"); value && value->is_int64()) {
    pack.set_int(lt::settings_pack::download_rate_limit,
                 static_cast<int>(value->as_int64()));
    config_.downloadLimit = static_cast<int>(value->as_int64());
  }
  if (auto const* value = request.if_contains("upload"); value && value->is_int64()) {
    pack.set_int(lt::settings_pack::upload_rate_limit,
                 static_cast<int>(value->as_int64()));
    config_.uploadLimit = static_cast<int>(value->as_int64());
  }
  session_->apply_settings(pack);
  configDirty_ = true;
  return limits();
}

std::vector<std::string> Engine::idsFrom(boost::json::object const& request) {
  std::vector<std::string> ids;
  if (auto const* id = request.if_contains("id"); id && id->is_string()) {
    ids.push_back(id->as_string().c_str());
  }
  if (auto const* list = request.if_contains("ids"); list && list->is_array()) {
    for (auto const& id : list->as_array()) {
      if (id.is_string()) ids.push_back(id.as_string().c_str());
    }
  }
  return ids;
}

std::vector<std::string> Engine::stringsFrom(boost::json::object const& request,
                                             char const* key) {
  std::vector<std::string> values;
  if (auto const* list = request.if_contains(key); list && list->is_array()) {
    for (auto const& value : list->as_array()) {
      if (value.is_string()) values.push_back(value.as_string().c_str());
    }
  } else if (auto const* value = request.if_contains(key); value && value->is_string()) {
    values.push_back(value->as_string().c_str());
  }
  return values;
}

void Engine::applyIPFilter() {
  lt::ip_filter filter;
  for (auto const& text : bannedIPs_) {
    lt::error_code ec;
    auto address = lt::make_address(text, ec);
    if (ec) continue;
    filter.add_rule(address, address, lt::ip_filter::blocked);
  }
  session_->set_ip_filter(filter);
}

void Engine::applyFirstLastPiecePriority(lt::torrent_handle const& handle, bool enabled) {
  auto info = handle.torrent_file();
  if (!info) return;
  auto const& storage = info->files();
  auto const pieceLength = info->piece_length();
  if (pieceLength <= 0) return;
  for (lt::file_index_t i{0}; static_cast<int>(i) < storage.num_files(); ++i) {
    auto const offset = storage.file_offset(i);
    auto const size = storage.file_size(i);
    if (size <= 0) continue;
    auto const first = static_cast<int>(offset / pieceLength);
    auto const last = static_cast<int>((offset + size - 1) / pieceLength);
    if (enabled) {
      handle.set_piece_deadline(lt::piece_index_t{first}, 0);
      handle.set_piece_deadline(lt::piece_index_t{last}, 0);
    } else {
      handle.reset_piece_deadline(lt::piece_index_t{first});
      handle.reset_piece_deadline(lt::piece_index_t{last});
    }
  }
}

boost::json::object Engine::importQbittorrent(boost::json::object const& request) {
  auto const* pathValue = request.if_contains("path");
  if (!pathValue || !pathValue->is_string()) {
    return errorResponse("import_qb", "missing BT_backup path");
  }
  auto const* saveValue = request.if_contains("savePath");
  std::string target = (saveValue && saveValue->is_string())
                           ? saveValue->as_string().c_str()
                           : "";
  bool startImported = true;
  if (auto const* start = request.if_contains("start"); start && start->is_bool()) {
    startImported = start->as_bool();
  }

  std::error_code ec;
  fs::path directory(pathValue->as_string().c_str());
  if (!fs::is_directory(directory, ec)) {
    return errorResponse("import_qb", "BT_backup directory not found");
  }

  int imported = 0;
  int skipped = 0;
  boost::json::array errors;
  std::set<std::string> withResume;

  auto importOne = [&](fs::path const& torrentPath, fs::path const* resumePath) {
    std::ifstream torrentIn(torrentPath, std::ios::binary);
    if (!torrentIn) {
      ++skipped;
      if (errors.size() < 12) errors.push_back(boost::json::value("unreadable " + torrentPath.filename().string()));
      return;
    }
    std::string torrentBytes((std::istreambuf_iterator<char>(torrentIn)),
                             std::istreambuf_iterator<char>());
    lt::error_code torrentError;
    lt::torrent_info info(lt::span<char const>(
                              torrentBytes.data(),
                              static_cast<std::ptrdiff_t>(torrentBytes.size())),
                          torrentError, lt::from_span);
    if (torrentError) {
      ++skipped;
      if (errors.size() < 12) {
        errors.push_back(boost::json::value(torrentPath.filename().string() + ": " + torrentError.message()));
      }
      return;
    }

    lt::add_torrent_params atp;
    lt::bdecode_node resumeNode;
    std::string resumeBytes;
    if (resumePath != nullptr) {
      std::ifstream resumeIn(*resumePath, std::ios::binary);
      resumeBytes.assign((std::istreambuf_iterator<char>(resumeIn)),
                         std::istreambuf_iterator<char>());
    }
    if (!resumeBytes.empty()) {
      lt::error_code resumeError;
      auto parsed = lt::read_resume_data(
          lt::span<char const>(resumeBytes.data(),
                               static_cast<std::ptrdiff_t>(resumeBytes.size())),
          resumeError);
      if (!resumeError) atp = std::move(parsed);
      else if (errors.size() < 12) {
        errors.push_back(boost::json::value(torrentPath.stem().string()
                                            + " resume: " + resumeError.message()));
      }
      lt::error_code bdecodeError;
      resumeNode = lt::bdecode(
          lt::span<char const>(resumeBytes.data(),
                               static_cast<std::ptrdiff_t>(resumeBytes.size())),
          bdecodeError);
    }

    atp.ti = std::make_shared<lt::torrent_info>(info);
    if (!target.empty()) atp.save_path = target;
    else if (atp.save_path.empty()) atp.save_path = config_.savePath;
    if (startImported) atp.flags &= ~lt::torrent_flags::paused;

    auto const hash = hashHex(atp.info_hashes.get_best());
    if (torrents_.find(hash) != torrents_.end()) {
      ++skipped;
      return;
    }
    lt::error_code addError;
    auto handle = session_->add_torrent(std::move(atp), addError);
    if (addError) {
      ++skipped;
      if (errors.size() < 12) {
        errors.push_back(boost::json::value(torrentPath.stem().string()
                                            + ": " + addError.message()));
      }
      return;
    }

    auto& meta = meta_[hash];
    if (resumeNode.type() == lt::bdecode_node::dict_t) {
      auto const name = resumeNode.dict_find_string_value("qBt-name");
      if (!name.empty()) meta.displayName = std::string(name);
      auto const category = resumeNode.dict_find_string_value("qBt-category");
      if (!category.empty()) meta.category = std::string(category);
      auto const tags = resumeNode.dict_find_list("qBt-tags");
      if (tags.type() == lt::bdecode_node::list_t) {
        for (int i = 0; i < tags.list_size(); ++i) {
          auto const tag = tags.list_string_value_at(i);
          if (!tag.empty()) meta.tags.push_back(std::string(tag));
        }
      }
      if (resumeNode.dict_find_int_value("qBt-firstLastPiecePriority", 0) != 0) {
        meta.firstLastPiecePriority = true;
        applyFirstLastPiecePriority(handle, true);
      }
    }
    if (!meta.category.empty() && categoryPaths_.find(meta.category) == categoryPaths_.end()) {
      categoryPaths_[meta.category] = "";
    }
    for (auto const& tag : meta.tags) {
      if (std::find(knownTags_.begin(), knownTags_.end(), tag) == knownTags_.end()) {
        knownTags_.push_back(tag);
      }
    }
    torrents_[hash] = handle;
    ++imported;
    saveResume(handle);
    emitLog("imported " + hash + " from qBittorrent");
  };

  for (auto const& entry : fs::directory_iterator(directory, ec)) {
    if (!entry.is_regular_file()) continue;
    if (entry.path().extension() != ".fastresume") continue;
    auto stem = entry.path().stem().string();
    withResume.insert(stem);
    auto torrentPath = directory / (stem + ".torrent");
    if (!fs::is_regular_file(torrentPath, ec)) {
      ++skipped;
      if (errors.size() < 12) errors.push_back(boost::json::value(stem + ": missing .torrent"));
      continue;
    }
    importOne(torrentPath, &entry.path());
  }

  // qBittorrent can have torrents that never wrote fastresume data yet.
  for (auto const& entry : fs::directory_iterator(directory, ec)) {
    if (!entry.is_regular_file()) continue;
    if (entry.path().extension() != ".torrent") continue;
    auto stem = entry.path().stem().string();
    if (withResume.find(stem) != withResume.end()) continue;
    importOne(entry.path(), nullptr);
  }

  configDirty_ = true;
  saveConfig();
  broadcastState(true);
  boost::json::object out;
  out["op"] = "import_qb";
  out["ok"] = true;
  out["imported"] = imported;
  out["skipped"] = skipped;
  out["errors"] = std::move(errors);
  return out;
}

boost::json::object Engine::stats() {
  std::int64_t received = 0;
  std::int64_t sent = 0;
  std::int64_t receivedAll = 0;
  std::int64_t sentAll = 0;
  std::int64_t downSpeed = 0;
  std::int64_t upSpeed = 0;
  std::int64_t wasted = 0;
  for (auto const& [hash, handle] : torrents_) {
    (void)hash;
    if (!handle.is_valid()) continue;
    auto const status = handle.status();
    received += status.total_download;
    sent += status.total_upload;
    receivedAll += status.all_time_download;
    sentAll += status.all_time_upload;
    downSpeed += status.download_payload_rate;
    upSpeed += status.upload_payload_rate;
    wasted += status.total_failed_bytes + status.total_redundant_bytes;
  }
  std::error_code ec;
  auto const space = fs::space(config_.savePath, ec);
  boost::json::object out;
  out["received"] = received;
  out["sent"] = sent;
  out["wasted"] = wasted;
  out["receivedAllTime"] = receivedAll;
  out["sentAllTime"] = sentAll;
  out["globalRatio"] = receivedAll > 0
                           ? static_cast<double>(sentAll) / static_cast<double>(receivedAll)
                           : 0.0;
  out["freeSpaceOnDisk"] = ec ? 0 : static_cast<std::int64_t>(space.available);
  out["downloadSpeed"] = downSpeed;
  out["uploadSpeed"] = upSpeed;
  return out;
}

boost::json::object Engine::setFlags(boost::json::object const& request) {
  auto const ids = idsFrom(request);
  auto const* sequential = request.if_contains("sequential");
  auto const* superSeeding = request.if_contains("superSeeding");
  auto const* autoManaged = request.if_contains("autoManaged");
  auto const* firstLast = request.if_contains("firstLastPiecePriority");
  for (auto const& id : ids) {
    auto handle = find(id);
    if (!handle.is_valid()) continue;
    if (sequential && sequential->is_bool()) {
      if (sequential->as_bool()) handle.set_flags(lt::torrent_flags::sequential_download);
      else handle.unset_flags(lt::torrent_flags::sequential_download);
    }
    if (superSeeding && superSeeding->is_bool()) {
      if (superSeeding->as_bool()) handle.set_flags(lt::torrent_flags::super_seeding);
      else handle.unset_flags(lt::torrent_flags::super_seeding);
    }
    if (autoManaged && autoManaged->is_bool()) {
      if (autoManaged->as_bool()) handle.set_flags(lt::torrent_flags::auto_managed);
      else handle.unset_flags(lt::torrent_flags::auto_managed);
    }
    if (firstLast && firstLast->is_bool()) {
      meta_[id].firstLastPiecePriority = firstLast->as_bool();
      applyFirstLastPiecePriority(handle, firstLast->as_bool());
    }
    saveResume(handle);
  }
  configDirty_ = true;
  boost::json::object out;
  out["op"] = "set_flags";
  out["ok"] = true;
  out["ids"] = boost::json::array();
  for (auto const& id : ids) out["ids"].as_array().push_back(boost::json::value(id));
  return out;
}

boost::json::object Engine::recheck(boost::json::object const& request) {
  for (auto const& id : idsFrom(request)) {
    auto handle = find(id);
    if (handle.is_valid()) handle.force_recheck();
  }
  boost::json::object out;
  out["op"] = "recheck";
  out["ok"] = true;
  return out;
}

boost::json::object Engine::queue(boost::json::object const& request) {
  auto const* move = request.if_contains("move");
  auto const direction = (move && move->is_string()) ? std::string(move->as_string().c_str()) : "";
  for (auto const& id : idsFrom(request)) {
    auto handle = find(id);
    if (!handle.is_valid()) continue;
    if (direction == "top") handle.queue_position_top();
    else if (direction == "up") handle.queue_position_up();
    else if (direction == "down") handle.queue_position_down();
    else if (direction == "bottom") handle.queue_position_bottom();
  }
  boost::json::object out;
  out["op"] = "queue";
  out["ok"] = true;
  return out;
}

boost::json::object Engine::rename(boost::json::object const& request) {
  auto const* id = request.if_contains("id");
  auto const* name = request.if_contains("name");
  if (!id || !id->is_string() || !name || !name->is_string()) {
    return errorResponse("rename", "missing id or name");
  }
  auto handle = find(id->as_string().c_str());
  if (!handle.is_valid()) return errorResponse("rename", "unknown torrent");
  auto const newName = std::string(name->as_string().c_str());
  auto info = handle.torrent_file();
  if (info) {
    auto const oldName = info->name();
    auto const& storage = info->files();
    if (storage.num_files() == 1) {
      handle.rename_file(lt::file_index_t{0}, newName);
    } else {
      for (lt::file_index_t i{0}; static_cast<int>(i) < storage.num_files(); ++i) {
        auto path = storage.file_path(i);
        if (path.rfind(oldName + "/", 0) == 0) {
          path = newName + path.substr(oldName.size());
        }
        handle.rename_file(i, path);
      }
    }
  }
  meta_[id->as_string().c_str()].displayName = newName;
  configDirty_ = true;
  saveResume(handle);
  broadcastState(false);
  boost::json::object out;
  out["op"] = "rename";
  out["ok"] = true;
  return out;
}

boost::json::object Engine::setLocation(boost::json::object const& request) {
  auto const* location = request.if_contains("location");
  if (!location || !location->is_string()) return errorResponse("set_location", "missing location");
  for (auto const& id : idsFrom(request)) {
    auto handle = find(id);
    if (handle.is_valid()) handle.move_storage(location->as_string().c_str());
  }
  boost::json::object out;
  out["op"] = "set_location";
  out["ok"] = true;
  return out;
}

boost::json::object Engine::setFilePriority(boost::json::object const& request) {
  auto const* id = request.if_contains("id");
  auto const* index = request.if_contains("fileIndex");
  auto const* priority = request.if_contains("priority");
  if (!id || !id->is_string() || !index || !index->is_int64() || !priority || !priority->is_int64()) {
    return errorResponse("file_priority", "missing id/fileIndex/priority");
  }
  auto handle = find(id->as_string().c_str());
  if (!handle.is_valid()) return errorResponse("file_priority", "unknown torrent");
  auto const value = static_cast<int>(priority->as_int64());
  lt::download_priority_t converted = lt::default_priority;
  if (value == 0) converted = lt::dont_download;
  else if (value == 6) converted = lt::download_priority_t{6};
  else if (value == 7) converted = lt::download_priority_t{7};
  handle.file_priority(lt::file_index_t{static_cast<int>(index->as_int64())}, converted);
  saveResume(handle);
  boost::json::object out;
  out["op"] = "file_priority";
  out["ok"] = true;
  return out;
}

boost::json::object Engine::categories() {
  boost::json::array list;
  for (auto const& [name, savePath] : categoryPaths_) {
    boost::json::object entry;
    entry["name"] = name;
    entry["savePath"] = savePath;
    list.push_back(std::move(entry));
  }
  boost::json::object out;
  out["op"] = "categories";
  out["ok"] = true;
  out["categories"] = std::move(list);
  return out;
}

boost::json::object Engine::createCategory(boost::json::object const& request) {
  auto const* name = request.if_contains("name");
  if (!name || !name->is_string()) return errorResponse("create_category", "missing name");
  auto const* savePath = request.if_contains("savePath");
  categoryPaths_[name->as_string().c_str()] =
      (savePath && savePath->is_string()) ? savePath->as_string().c_str() : "";
  configDirty_ = true;
  return categories();
}

boost::json::object Engine::removeCategories(boost::json::object const& request) {
  for (auto const& name : stringsFrom(request, "names")) {
    categoryPaths_.erase(name);
    for (auto& [hash, meta] : meta_) {
      (void)hash;
      if (meta.category == name) meta.category.clear();
    }
  }
  configDirty_ = true;
  return categories();
}

boost::json::object Engine::setCategory(boost::json::object const& request) {
  auto const* category = request.if_contains("category");
  std::string name = (category && category->is_string()) ? category->as_string().c_str() : "";
  if (!name.empty() && categoryPaths_.find(name) == categoryPaths_.end()) {
    categoryPaths_[name] = "";
  }
  for (auto const& id : idsFrom(request)) {
    meta_[id].category = name;
  }
  configDirty_ = true;
  broadcastState(false);
  boost::json::object out;
  out["op"] = "set_category";
  out["ok"] = true;
  return out;
}

boost::json::object Engine::tags() {
  boost::json::array list;
  for (auto const& tag : knownTags_) list.push_back(boost::json::value(tag));
  boost::json::object out;
  out["op"] = "tags";
  out["ok"] = true;
  out["tags"] = std::move(list);
  return out;
}

boost::json::object Engine::createTags(boost::json::object const& request) {
  for (auto const& tag : stringsFrom(request, "names")) {
    if (std::find(knownTags_.begin(), knownTags_.end(), tag) == knownTags_.end()) {
      knownTags_.push_back(tag);
    }
  }
  configDirty_ = true;
  return tags();
}

boost::json::object Engine::deleteTags(boost::json::object const& request) {
  for (auto const& tag : stringsFrom(request, "names")) {
    knownTags_.erase(std::remove(knownTags_.begin(), knownTags_.end(), tag), knownTags_.end());
    for (auto& [hash, meta] : meta_) {
      (void)hash;
      meta.tags.erase(std::remove(meta.tags.begin(), meta.tags.end(), tag), meta.tags.end());
    }
  }
  configDirty_ = true;
  broadcastState(false);
  return tags();
}

boost::json::object Engine::addRemoveTags(boost::json::object const& request, bool add) {
  auto const tags = stringsFrom(request, "tags");
  for (auto const& id : idsFrom(request)) {
    auto& list = meta_[id].tags;
    for (auto const& tag : tags) {
      if (add) {
        if (std::find(list.begin(), list.end(), tag) == list.end()) list.push_back(tag);
        if (std::find(knownTags_.begin(), knownTags_.end(), tag) == knownTags_.end()) {
          knownTags_.push_back(tag);
        }
      } else {
        list.erase(std::remove(list.begin(), list.end(), tag), list.end());
      }
    }
  }
  configDirty_ = true;
  broadcastState(false);
  boost::json::object out;
  out["op"] = add ? "add_tags" : "remove_tags";
  out["ok"] = true;
  return out;
}

boost::json::object Engine::addTrackers(boost::json::object const& request) {
  auto const* id = request.if_contains("id");
  if (!id || !id->is_string()) return errorResponse("add_trackers", "missing id");
  auto handle = find(id->as_string().c_str());
  if (!handle.is_valid()) return errorResponse("add_trackers", "unknown torrent");
  for (auto const& url : stringsFrom(request, "urls")) {
    handle.add_tracker(lt::announce_entry(url));
  }
  saveResume(handle);
  boost::json::object out;
  out["op"] = "add_trackers";
  out["ok"] = true;
  return out;
}

boost::json::object Engine::editTracker(boost::json::object const& request) {
  auto const* id = request.if_contains("id");
  auto const* oldURL = request.if_contains("oldURL");
  auto const* newURL = request.if_contains("newURL");
  if (!id || !id->is_string() || !oldURL || !oldURL->is_string()
      || !newURL || !newURL->is_string()) {
    return errorResponse("edit_tracker", "missing id/oldURL/newURL");
  }
  auto handle = find(id->as_string().c_str());
  if (!handle.is_valid()) return errorResponse("edit_tracker", "unknown torrent");
  std::vector<lt::announce_entry> trackers = handle.trackers();
  for (auto& tracker : trackers) {
    if (tracker.url == oldURL->as_string()) tracker.url = newURL->as_string().c_str();
  }
  handle.replace_trackers(trackers);
  handle.force_reannounce();
  saveResume(handle);
  boost::json::object out;
  out["op"] = "edit_tracker";
  out["ok"] = true;
  return out;
}

boost::json::object Engine::removeTrackers(boost::json::object const& request) {
  auto const* id = request.if_contains("id");
  if (!id || !id->is_string()) return errorResponse("remove_trackers", "missing id");
  auto handle = find(id->as_string().c_str());
  if (!handle.is_valid()) return errorResponse("remove_trackers", "unknown torrent");
  auto removed = stringsFrom(request, "urls");
  std::vector<lt::announce_entry> trackers = handle.trackers();
  trackers.erase(std::remove_if(trackers.begin(), trackers.end(), [&](auto const& tracker) {
                   return std::find(removed.begin(), removed.end(), tracker.url) != removed.end();
                 }),
                 trackers.end());
  handle.replace_trackers(trackers);
  saveResume(handle);
  boost::json::object out;
  out["op"] = "remove_trackers";
  out["ok"] = true;
  return out;
}

boost::json::object Engine::reannounce(boost::json::object const& request) {
  auto const* id = request.if_contains("id");
  if (!id || !id->is_string()) return errorResponse("reannounce", "missing id");
  auto handle = find(id->as_string().c_str());
  if (handle.is_valid()) handle.force_reannounce();
  boost::json::object out;
  out["op"] = "reannounce";
  out["ok"] = true;
  return out;
}

boost::json::object Engine::addWebSeeds(boost::json::object const& request) {
  auto const* id = request.if_contains("id");
  if (!id || !id->is_string()) return errorResponse("add_web_seeds", "missing id");
  auto handle = find(id->as_string().c_str());
  if (!handle.is_valid()) return errorResponse("add_web_seeds", "unknown torrent");
  for (auto const& url : stringsFrom(request, "urls")) handle.add_url_seed(url);
  saveResume(handle);
  boost::json::object out;
  out["op"] = "add_web_seeds";
  out["ok"] = true;
  return out;
}

boost::json::object Engine::editWebSeed(boost::json::object const& request) {
  auto const* id = request.if_contains("id");
  auto const* oldURL = request.if_contains("oldURL");
  auto const* newURL = request.if_contains("newURL");
  if (!id || !id->is_string() || !oldURL || !oldURL->is_string()
      || !newURL || !newURL->is_string()) {
    return errorResponse("edit_web_seed", "missing id/oldURL/newURL");
  }
  auto handle = find(id->as_string().c_str());
  if (!handle.is_valid()) return errorResponse("edit_web_seed", "unknown torrent");
  handle.remove_url_seed(oldURL->as_string().c_str());
  handle.add_url_seed(newURL->as_string().c_str());
  saveResume(handle);
  boost::json::object out;
  out["op"] = "edit_web_seed";
  out["ok"] = true;
  return out;
}

boost::json::object Engine::removeWebSeeds(boost::json::object const& request) {
  auto const* id = request.if_contains("id");
  if (!id || !id->is_string()) return errorResponse("remove_web_seeds", "missing id");
  auto handle = find(id->as_string().c_str());
  if (!handle.is_valid()) return errorResponse("remove_web_seeds", "unknown torrent");
  for (auto const& url : stringsFrom(request, "urls")) handle.remove_url_seed(url);
  saveResume(handle);
  boost::json::object out;
  out["op"] = "remove_web_seeds";
  out["ok"] = true;
  return out;
}

boost::json::object Engine::banIPs(boost::json::object const& request, bool ban) {
  auto const ips = stringsFrom(request, "ips");
  for (auto const& ip : ips) {
    if (ban) {
      if (std::find(bannedIPs_.begin(), bannedIPs_.end(), ip) == bannedIPs_.end()) {
        bannedIPs_.push_back(ip);
      }
    } else {
      bannedIPs_.erase(std::remove(bannedIPs_.begin(), bannedIPs_.end(), ip), bannedIPs_.end());
    }
  }
  applyIPFilter();
  configDirty_ = true;
  boost::json::array list;
  for (auto const& ip : bannedIPs_) list.push_back(boost::json::value(ip));
  boost::json::object out;
  out["op"] = ban ? "ban_ips" : "unban_ips";
  out["ok"] = true;
  out["ips"] = std::move(list);
  return out;
}

boost::json::object Engine::handle(boost::json::object const& request) {
  auto const op = request.if_contains("op");
  if (!op || !op->is_string()) return errorResponse("", "missing op");
  try {
    auto const name = std::string(op->as_string().c_str());
    if (name == "hello") {
      boost::json::object out;
      out["op"] = "hello";
      out["ok"] = true;
      out["v"] = 1;
      out["engine"] = "drift-engine";
      out["libtorrent"] = LIBTORRENT_VERSION;
      out["listenPort"] = config_.listenPort;
      return out;
    }
    if (name == "ping") {
      boost::json::object out;
      out["op"] = "pong";
      out["ok"] = true;
      out["engine"] = "drift-engine";
      out["libtorrent"] = LIBTORRENT_VERSION;
      out["listenPort"] = config_.listenPort;
      return out;
    }
    if (name == "list") return list();
    if (name == "details") {
      auto const* id = request.if_contains("id");
      if (!id || !id->is_string()) return errorResponse("details", "missing id");
      return details(id->as_string().c_str());
    }
    if (name == "export_torrent") {
      auto const* id = request.if_contains("id");
      if (!id || !id->is_string()) return errorResponse("export_torrent", "missing id");
      return exportTorrent(id->as_string().c_str());
    }
    if (name == "piece_states") {
      auto const* id = request.if_contains("id");
      if (!id || !id->is_string()) return errorResponse("piece_states", "missing id");
      return pieceStates(id->as_string().c_str());
    }
    if (name == "add") return add(request);
    if (name == "remove") return remove(request);
    if (name == "start") return startStop(request, true);
    if (name == "stop") return startStop(request, false);
    if (name == "limits") return limits();
    if (name == "set_limits") return setLimits(request);
    if (name == "set_flags") return setFlags(request);
    if (name == "force_start") {
      for (auto const& id : idsFrom(request)) {
        auto handle = find(id);
        if (!handle.is_valid()) continue;
        handle.unset_flags(lt::torrent_flags::auto_managed);
        handle.resume();
      }
      boost::json::object out;
      out["op"] = "force_start";
      out["ok"] = true;
      return out;
    }
    if (name == "recheck") return recheck(request);
    if (name == "queue") return queue(request);
    if (name == "rename") return rename(request);
    if (name == "set_location") return setLocation(request);
    if (name == "file_priority") return setFilePriority(request);
    if (name == "categories") return categories();
    if (name == "create_category") return createCategory(request);
    if (name == "edit_category") return createCategory(request);
    if (name == "remove_categories") return removeCategories(request);
    if (name == "set_category") return setCategory(request);
    if (name == "tags") return tags();
    if (name == "create_tags") return createTags(request);
    if (name == "delete_tags") return deleteTags(request);
    if (name == "add_tags") return addRemoveTags(request, true);
    if (name == "remove_tags") return addRemoveTags(request, false);
    if (name == "add_trackers") return addTrackers(request);
    if (name == "edit_tracker") return editTracker(request);
    if (name == "remove_trackers") return removeTrackers(request);
    if (name == "reannounce") return reannounce(request);
    if (name == "add_web_seeds") return addWebSeeds(request);
    if (name == "edit_web_seed") return editWebSeed(request);
    if (name == "remove_web_seeds") return removeWebSeeds(request);
    if (name == "ban_ips") return banIPs(request, true);
    if (name == "unban_ips") return banIPs(request, false);
    if (name == "banned_ips") {
      boost::json::array list;
      for (auto const& ip : bannedIPs_) list.push_back(boost::json::value(ip));
      boost::json::object out;
      out["op"] = "banned_ips";
      out["ok"] = true;
      out["ips"] = std::move(list);
      return out;
    }
    if (name == "import_qb") return importQbittorrent(request);
    if (name == "stats") {
      auto out = stats();
      out["op"] = "stats";
      out["ok"] = true;
      return out;
    }
    return errorResponse(name, "unknown op");
  } catch (std::exception const& e) {
    return errorResponse("", e.what());
  }
}

std::vector<std::string> Engine::hashes() const {
  std::vector<std::string> out;
  for (auto const& [hash, handle] : torrents_) {
    if (handle.is_valid()) out.push_back(hash);
  }
  return out;
}

float Engine::progress(std::string const& hash) const {
  auto handle = find(hash);
  if (!handle.is_valid()) return -1.f;
  return handle.status().progress;
}

void Engine::shutdown() {
  if (!session_) return;
  saveAllResume();
  saveConfig();
  emitLog("engine stop");
  session_->pause();
  session_.reset();
  initialized_ = false;
}

}  // namespace drift
