#include "uds_server.hpp"

#include <algorithm>
#include <cerrno>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <filesystem>
#include <poll.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

namespace drift {
namespace {
constexpr std::uint32_t kMaxFrame = 32u * 1024u * 1024u;

std::int64_t unixNow() {
  return std::chrono::duration_cast<std::chrono::seconds>(
             std::chrono::system_clock::now().time_since_epoch())
      .count();
}

std::string frame(std::string const& payload) {
  std::string out;
  out.resize(4 + payload.size());
  auto const size = static_cast<std::uint32_t>(payload.size());
  out[0] = static_cast<char>(size & 0xff);
  out[1] = static_cast<char>((size >> 8) & 0xff);
  out[2] = static_cast<char>((size >> 16) & 0xff);
  out[3] = static_cast<char>((size >> 24) & 0xff);
  std::memcpy(out.data() + 4, payload.data(), payload.size());
  return out;
}
}  // namespace

UdsServer::~UdsServer() { stop(); }

bool UdsServer::start(std::string const& path, Handler handler, std::string& error) {
  stop();
  path_ = path;
  handler_ = std::move(handler);

  std::error_code ec;
  auto parent = std::filesystem::path(path_).parent_path();
  if (!parent.empty()) std::filesystem::create_directories(parent, ec);
  ::unlink(path_.c_str());

  if (path_.size() >= sizeof(sockaddr_un{}.sun_path)) {
    error = "socket path too long";
    return false;
  }

  listenFd_ = ::socket(AF_UNIX, SOCK_STREAM, 0);
  if (listenFd_ < 0) {
    error = std::string("socket: ") + std::strerror(errno);
    return false;
  }
  sockaddr_un addr{};
  addr.sun_family = AF_UNIX;
  std::strncpy(addr.sun_path, path_.c_str(), sizeof(addr.sun_path) - 1);
  if (::bind(listenFd_, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0) {
    error = std::string("bind: ") + std::strerror(errno);
    ::close(listenFd_);
    listenFd_ = -1;
    return false;
  }
  ::chmod(path_.c_str(), 0600);
  if (::listen(listenFd_, 8) != 0) {
    error = std::string("listen: ") + std::strerror(errno);
    ::close(listenFd_);
    listenFd_ = -1;
    ::unlink(path_.c_str());
    return false;
  }
  int flags = ::fcntl(listenFd_, F_GETFL, 0);
  if (flags >= 0) ::fcntl(listenFd_, F_SETFL, flags | O_NONBLOCK);
  return true;
}

void UdsServer::stop() {
  for (auto& client : clients_) {
    if (client.fd >= 0) ::close(client.fd);
  }
  clients_.clear();
  if (listenFd_ >= 0) {
    ::close(listenFd_);
    listenFd_ = -1;
  }
  if (!path_.empty()) {
    ::unlink(path_.c_str());
    path_.clear();
  }
}

void UdsServer::poll(int timeoutMs) {
  if (listenFd_ < 0) return;
  std::vector<pollfd> fds;
  fds.push_back(pollfd{listenFd_, POLLIN, 0});
  for (auto const& client : clients_) {
    fds.push_back(pollfd{client.fd, static_cast<short>(POLLIN | POLLOUT), 0});
  }
  int const ready = ::poll(fds.data(), static_cast<nfds_t>(fds.size()), timeoutMs);
  if (ready < 0) {
    if (errno == EINTR) return;
    return;
  }
  if (fds[0].revents & POLLIN) acceptClients();

  for (std::size_t i = 0; i < clients_.size(); ++i) {
    auto& client = clients_[i];
    if (client.fd < 0) continue;
    auto const revents = fds[i + 1].revents;
    if (revents & (POLLERR | POLLHUP | POLLNVAL)) {
      closeClient(client);
      continue;
    }
    if (revents & POLLIN) readClient(client);
    if (client.fd >= 0 && (revents & POLLOUT)) flushClient(client);
  }
  clients_.erase(std::remove_if(clients_.begin(), clients_.end(),
                                [](Client const& client) { return client.fd < 0; }),
                 clients_.end());
}

void UdsServer::acceptClients() {
  for (;;) {
    int fd = ::accept(listenFd_, nullptr, nullptr);
    if (fd < 0) {
      if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) return;
      return;
    }
    Client client;
    client.fd = fd;
    client.lastFrame = unixNow();
    int flags = ::fcntl(fd, F_GETFL, 0);
    if (flags >= 0) ::fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    clients_.push_back(std::move(client));
  }
}

void UdsServer::readClient(Client& client) {
  char buffer[65536];
  for (;;) {
    ssize_t const count = ::recv(client.fd, buffer, sizeof(buffer), 0);
    if (count > 0) {
      client.in.insert(client.in.end(), buffer, buffer + count);
      client.lastFrame = unixNow();
      if (!processFrames(client)) return;
      continue;
    }
    if (count == 0) {
      closeClient(client);
      return;
    }
    if (errno == EAGAIN || errno == EWOULDBLOCK) return;
    if (errno == EINTR) continue;
    closeClient(client);
    return;
  }
}

bool UdsServer::processFrames(Client& client) {
  while (client.in.size() >= 4) {
    auto const* bytes = reinterpret_cast<unsigned char const*>(client.in.data());
    std::uint32_t size = static_cast<std::uint32_t>(bytes[0])
                         | (static_cast<std::uint32_t>(bytes[1]) << 8)
                         | (static_cast<std::uint32_t>(bytes[2]) << 16)
                         | (static_cast<std::uint32_t>(bytes[3]) << 24);
    if (size > kMaxFrame) {
      closeClient(client);
      return false;
    }
    if (client.in.size() < 4 + size) return true;
    std::string payload(client.in.data() + 4, client.in.data() + 4 + size);
    client.in.erase(client.in.begin(), client.in.begin() + 4 + size);
    handleFrame(client, payload);
    if (client.fd < 0) return false;
  }
  return true;
}

void UdsServer::handleFrame(Client& client, std::string const& payload) {
  boost::system::error_code ec;
  auto value = boost::json::parse(payload, ec);
  boost::json::object response;
  if (ec || !value.is_object()) {
    response["op"] = "error";
    response["ok"] = false;
    response["message"] = "invalid JSON";
  } else if (!handler_) {
    response["op"] = "error";
    response["ok"] = false;
    response["message"] = "no handler";
  } else {
    response = handler_(value.as_object());
  }
  enqueue(client, boost::json::serialize(response));
}

void UdsServer::send(boost::json::object const& message) {
  auto const payload = boost::json::serialize(message);
  for (auto& client : clients_) {
    if (client.fd >= 0) enqueue(client, payload);
  }
}

void UdsServer::enqueue(Client& client, std::string const& payload) {
  if (client.fd < 0) return;
  auto const framed = frame(payload);
  client.out.insert(client.out.end(), framed.begin(), framed.end());
  flushClient(client);
}

void UdsServer::flushClient(Client& client) {
  while (!client.out.empty() && client.fd >= 0) {
    ssize_t const written = ::send(client.fd, client.out.data(), client.out.size(), 0);
    if (written > 0) {
      client.out.erase(client.out.begin(), client.out.begin() + written);
      continue;
    }
    if (written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return;
    if (written < 0 && errno == EINTR) continue;
    closeClient(client);
    return;
  }
}

void UdsServer::closeClient(Client& client) {
  if (client.fd >= 0) ::close(client.fd);
  client.fd = -1;
  client.in.clear();
  client.out.clear();
}

std::int64_t UdsServer::lastClientFrame() const {
  std::int64_t latest = 0;
  for (auto const& client : clients_) {
    if (client.fd >= 0) latest = std::max(latest, client.lastFrame);
  }
  return latest;
}

}  // namespace drift
