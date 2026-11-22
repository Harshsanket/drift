// SPDX-License-Identifier: BSD-3-Clause
// Minimal Unix-domain-socket server for the length-prefixed JSON-lines
// protocol (EMBEDDED-ENGINE.md §5). One response per request; engine events
// are broadcast to every connected client.
#pragma once

#include <boost/json.hpp>

#include <cstdint>
#include <functional>
#include <string>
#include <vector>

namespace drift {

class UdsServer {
 public:
  using Handler = std::function<boost::json::object(boost::json::object const&)>;

  UdsServer() = default;
  ~UdsServer();

  bool start(std::string const& path, Handler handler, std::string& error);
  void stop();
  void poll(int timeoutMs);
  void send(boost::json::object const& message);

  bool hasClient() const { return !clients_.empty(); }
  std::int64_t lastClientFrame() const;

 private:
  struct Client {
    int fd = -1;
    std::vector<char> in;
    std::vector<char> out;
    std::int64_t lastFrame = 0;
  };

  void acceptClients();
  void readClient(Client& client);
  void flushClient(Client& client);
  void closeClient(Client& client);
  void enqueue(Client& client, std::string const& payload);
  bool processFrames(Client& client);
  void handleFrame(Client& client, std::string const& payload);

  int listenFd_ = -1;
  std::string path_;
  std::vector<Client> clients_;
  Handler handler_;
};

}  // namespace drift
