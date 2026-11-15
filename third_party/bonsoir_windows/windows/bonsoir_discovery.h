#pragma once

#include "bonsoir_action.h"

namespace bonsoir_windows {
  // What a browse callback reported, copied out of the DNS records so the
  // platform thread can use it after the callback has returned.
  struct BrowseResult {
    DWORD status;
    std::string name;
    std::string type;
    // The service's TTL reached zero: it left the network.
    bool lost = false;
    std::map<std::string, std::string> attributes;
  };

  // What a resolve callback reported, copied out of the service instance.
  struct ResolveResult {
    DWORD status;
    // Key of this resolve in BonsoirDiscovery::resolvingServices.
    uint32_t resolveId;
    // False when Windows gave no instance name, so the service is unknown.
    bool named = false;
    std::string name = "NULL";
    std::string type = "NULL";
    bool hasInstance = false;
    std::vector<std::string> hostAddresses;
    std::optional<std::string> hostname;
    int port = 0;
    std::map<std::string, std::string> attributes;
  };

  // A resolve Windows has not answered yet.
  struct ResolvingService {
    // "<name>.<type>", so the same service is not resolved twice at once.
    std::string key;
    DNS_SERVICE_CANCEL cancelHandle{};
  };

  // Every member is touched on the platform thread only. The DNS callbacks
  // copy what Windows gave them and post it there; see browseCallback.
  class BonsoirDiscovery : public BonsoirAction {
   public:
    std::string type;
    std::list<std::shared_ptr<BonsoirService>> services;
    // std::map keeps each entry at a fixed address, which Windows needs for
    // the cancel handle.
    std::map<uint32_t, ResolvingService> resolvingServices;

    BonsoirDiscovery(
      int _id,
      bool _printLogs,
      flutter::BinaryMessenger *_binaryMessenger,
      std::string type
    );

    ~BonsoirDiscovery();

    void start() override;

    void stop() override;

    std::shared_ptr<BonsoirService> findService(std::string serviceName, std::string serviceType);

    void resolveService(std::string serviceName, std::string serviceType);

    void dispose() override;

    void onBrowseResult(const BrowseResult &result);

    void onResolveResult(const ResolveResult &result);

   private:
    // Marks the discovery stopped, tells Dart, and cancels what is still
    // resolving. The caller deals with the browse itself.
    void finish();

    uint32_t nextResolveId = 1;
  };

  void browseCallback(DWORD status, PVOID context, PDNS_RECORD dnsRecord);

  void resolveCallback(DWORD status, PVOID context, PDNS_SERVICE_INSTANCE serviceInstance);
}  // namespace bonsoir_windows
