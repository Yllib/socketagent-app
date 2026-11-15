#include "bonsoir_discovery.h"

#include "generated.h"
#include "utilities.h"

#include <optional>
#include <ws2tcpip.h>

using namespace flutter;

// Threading: Windows calls browseCallback and resolveCallback on its own
// threads, and DnsServiceBrowseCancel waits on the platform thread for a
// running callback to return. The callbacks therefore share no state with the
// discovery. They copy what Windows gave them and post it to the platform
// thread, and their context is a number, never a pointer, so one that arrives
// after the discovery is gone finds nothing to touch.

namespace bonsoir_windows {
  namespace {
    // The context packs the discovery's token into the high half of a
    // pointer-sized number and, for a resolve, its ID into the low half.
    static_assert(sizeof(PVOID) == 8, "The callback context needs a 64-bit pointer.");

    PVOID callbackContext(uint32_t token, uint32_t resolveId = 0) {
      return reinterpret_cast<PVOID>((static_cast<uintptr_t>(token) << 32) | resolveId);
    }

    uint32_t contextToken(PVOID context) {
      return static_cast<uint32_t>(reinterpret_cast<uintptr_t>(context) >> 32);
    }

    uint32_t contextResolveId(PVOID context) {
      return static_cast<uint32_t>(reinterpret_cast<uintptr_t>(context));
    }

    std::vector<std::string> serviceInstanceIpAddresses(PDNS_SERVICE_INSTANCE serviceInstance) {
      std::vector<std::string> hostAddresses;
      char buffer[INET6_ADDRSTRLEN] = {};

      if (serviceInstance->ip4Address != nullptr) {
        IN_ADDR address{};
        address.S_un.S_addr = *serviceInstance->ip4Address;
        if (InetNtopA(AF_INET, &address, buffer, INET_ADDRSTRLEN) != nullptr) {
          hostAddresses.push_back(std::string(buffer));
        }
      }

      if (serviceInstance->ip6Address != nullptr) {
        if (InetNtopA(AF_INET6, serviceInstance->ip6Address, buffer, INET6_ADDRSTRLEN) != nullptr) {
          hostAddresses.push_back(std::string(buffer));
        }
      }

      return hostAddresses;
    }

    // Fills `result` from a browse callback's record list. Returns false when
    // the list names no service.
    bool readBrowseRecords(PDNS_RECORD records, BrowseResult &result) {
      PDNS_RECORD pointer = records;
      while (pointer != nullptr && pointer->wType != DNS_TYPE_PTR) {
        pointer = pointer->pNext;
      }
      if (pointer == nullptr || pointer->Data.PTR.pNameHost == nullptr) {
        return false;
      }
      auto serviceData = parseBonjourFqdn(toUtf8(pointer->Data.PTR.pNameHost));
      result.name = std::get<0>(serviceData);
      result.type = std::get<1>(serviceData);
      result.lost = pointer->dwTtl == 0;
      for (PDNS_RECORD record = records; record != nullptr; record = record->pNext) {
        if (record->wType != DNS_TYPE_TEXT) {
          continue;
        }
        DNS_TXT_DATAW *data = &record->Data.TXT;
        for (DWORD s = 0; s < data->dwStringCount; s++) {
          std::string entry = toUtf8(std::wstring(data->pStringArray[s]));
          std::string key = entry;
          std::string value = "";
          size_t splitIndex = entry.find("=");
          if (splitIndex != std::string::npos) {
            key = entry.substr(0, splitIndex);
            value = entry.substr(splitIndex + 1);
          }
          if (!key.empty()) {
            result.attributes.insert({key, value});
          }
        }
      }
      return true;
    }

    void readServiceInstance(PDNS_SERVICE_INSTANCE serviceInstance, ResolveResult &result) {
      if (serviceInstance->pszInstanceName) {
        auto serviceData = parseBonjourFqdn(toUtf8(serviceInstance->pszInstanceName));
        result.name = std::get<0>(serviceData);
        result.type = std::get<1>(serviceData);
        result.named = true;
      }
      result.hostAddresses = serviceInstanceIpAddresses(serviceInstance);
      if (serviceInstance->pszHostName != nullptr) {
        result.hostname = toUtf8(serviceInstance->pszHostName);
      }
      result.port = serviceInstance->wPort;
      if (serviceInstance->dwPropertyCount > 0 && serviceInstance->keys != nullptr) {
        for (DWORD i = 0; i < serviceInstance->dwPropertyCount; i++) {
          if (serviceInstance->keys[i] != nullptr) {
            std::string value = "";
            if (serviceInstance->values != nullptr && serviceInstance->values[i] != nullptr) {
              value = toUtf8(serviceInstance->values[i]);
            }
            result.attributes[toUtf8(serviceInstance->keys[i])] = value;
          }
        }
      }
      result.hasInstance = true;
    }
  }  // namespace

  BonsoirDiscovery::BonsoirDiscovery(
    int _id,
    bool _printLogs,
    BinaryMessenger *_binaryMessenger,
    std::string _type
  )
    : BonsoirAction("discovery", Generated::discoveryMessages, _id, _printLogs, _binaryMessenger),
      type(_type) {}

  BonsoirDiscovery::~BonsoirDiscovery() {
    dispose();
  }

  void BonsoirDiscovery::start() {
    auto queryName = toUtf16(type + ".local");
    DNS_SERVICE_BROWSE_REQUEST browseRequest{};
    browseRequest.Version = DNS_QUERY_REQUEST_VERSION1;
    browseRequest.InterfaceIndex = 0;
    browseRequest.QueryName = queryName.c_str();
    browseRequest.pBrowseCallback = browseCallback;
    browseRequest.pQueryContext = callbackContext(token);
    DNS_STATUS status = DnsServiceBrowse(&browseRequest, &cancelHandle);
    if (status == DNS_REQUEST_PENDING) {
      BonsoirAction::start();
      onSuccess(Generated::discoveryStarted, nullptr, std::list<std::string>{type});
    } else {
      // Stays alive so Dart receives the error; its stop() disposes this.
      onError(EncodableValue(std::to_string(status)), std::list<std::string>{std::to_string(status)});
    }
  }

  void BonsoirDiscovery::stop() {
    if (!isRunning()) {
      return;
    }
    finish();
    // Waits for a browse callback that is running. It only posts, so the
    // wait is short and cannot deadlock on this thread.
    DnsServiceBrowseCancel(&cancelHandle);
  }

  void BonsoirDiscovery::finish() {
    BonsoirAction::stop();
    onSuccess(Generated::discoveryStopped, nullptr, std::list<std::string>{type});
    for (auto &[resolveId, resolving] : resolvingServices) {
      DnsServiceResolveCancel(&resolving.cancelHandle);
    }
    resolvingServices.clear();
    services.clear();
  }

  std::shared_ptr<BonsoirService> BonsoirDiscovery::findService(std::string serviceName, std::string serviceType) {
    for (auto &found_service : this->services) {
      if (found_service->name == serviceName && found_service->type == serviceType) {
        return found_service;
      }
    }
    return nullptr;
  }

  void BonsoirDiscovery::resolveService(std::string serviceName, std::string serviceType) {
    if (!isRunning()) {
      return;
    }
    std::shared_ptr<BonsoirService> servicePtr = findService(serviceName, serviceType);
    if (servicePtr == nullptr) {
      onError(EncodableValue(), std::list<std::string>{serviceName, serviceType}, logMessages.find(Generated::discoveryUndiscoveredServiceResolveFailed)->second);
      return;
    }

    std::string key = servicePtr->name + "." + servicePtr->type;
    for (auto const &[resolveId, resolving] : resolvingServices) {
      if (resolving.key == key) {
        // Its answer will serve this request too.
        return;
      }
    }

    auto queryName = toUtf16(key + ".local");
    uint32_t resolveId = nextResolveId++;
    ResolvingService &resolving = resolvingServices[resolveId];
    resolving.key = key;
    DNS_SERVICE_RESOLVE_REQUEST resolveRequest{};
    resolveRequest.Version = DNS_QUERY_REQUEST_VERSION1;
    resolveRequest.InterfaceIndex = 0;
    resolveRequest.QueryName = const_cast<PWSTR>(queryName.c_str());
    resolveRequest.pResolveCompletionCallback = resolveCallback;
    resolveRequest.pQueryContext = callbackContext(token, resolveId);
    DNS_STATUS status = DnsServiceResolve(&resolveRequest, &resolving.cancelHandle);
    if (status != DNS_REQUEST_PENDING) {
      resolvingServices.erase(resolveId);
      onSuccess(Generated::discoveryServiceResolveFailed, servicePtr, std::list<std::string>{std::to_string(status)});
    }
  }

  void BonsoirDiscovery::dispose() {
    stop();
    BonsoirAction::dispose();
  }

  void BonsoirDiscovery::onBrowseResult(const BrowseResult &result) {
    if (!isRunning()) {
      return;
    }
    if (result.status == ERROR_CANCELLED) {
      // Windows ended the browse itself, so there is nothing left to cancel.
      finish();
      return;
    }
    if (result.status != ERROR_SUCCESS) {
      onError(EncodableValue(std::to_string(result.status)), std::list<std::string>{std::to_string(result.status)});
      stop();
      return;
    }

    std::shared_ptr<BonsoirService> servicePtr = findService(result.name, result.type);
    if (result.lost) {
      if (servicePtr) {
        onSuccess(Generated::discoveryServiceLost, servicePtr);
        services.remove(servicePtr);
      }
      return;
    }
    std::shared_ptr<BonsoirService> newServicePtr = std::make_shared<BonsoirService>(
      result.name,
      result.type,
      0,
      std::vector<std::string>(),
      std::nullopt,
      result.attributes
    );
    services.push_back(newServicePtr);
    if (servicePtr) {
      if (!servicePtr->hostAddresses.empty()) {
        newServicePtr->hostAddresses = servicePtr->hostAddresses;
      }
      if (servicePtr->hostname) {
        newServicePtr->hostname = servicePtr->hostname;
      }
      if (servicePtr->port != 0) {
        newServicePtr->port = servicePtr->port;
      }
      services.remove(servicePtr);
      onSuccess(Generated::discoveryServiceUpdated, newServicePtr);
    } else {
      onSuccess(Generated::discoveryServiceFound, newServicePtr);
    }
  }

  void BonsoirDiscovery::onResolveResult(const ResolveResult &result) {
    resolvingServices.erase(result.resolveId);
    if (!isRunning()) {
      return;
    }
    std::shared_ptr<BonsoirService> servicePtr = result.named ? findService(result.name, result.type) : nullptr;
    const std::string &resolveFailed = logMessages.find(Generated::discoveryServiceResolveFailed)->second;
    if (result.status != ERROR_SUCCESS) {
      std::string status = std::to_string(result.status);
      if (servicePtr) {
        onSuccess(Generated::discoveryServiceResolveFailed, servicePtr, std::list<std::string>{status});
      } else {
        onError(EncodableValue(status), std::list<std::string>{"NULL", status}, resolveFailed);
      }
      return;
    }
    if (!servicePtr) {
      onError(EncodableValue(), std::list<std::string>{result.name, result.type}, resolveFailed);
      return;
    }
    if (result.hasInstance) {
      servicePtr->hostAddresses = result.hostAddresses;
      servicePtr->hostname = result.hostname;
      servicePtr->port = result.port;
      servicePtr->attributes = result.attributes;
    }
    onSuccess(Generated::discoveryServiceResolved, servicePtr);
  }

  // Runs on a Windows thread. Copies, frees, posts; touches no discovery.
  void browseCallback(DWORD status, PVOID context, PDNS_RECORD dnsRecord) {
    BrowseResult result{status};
    bool usable = status != ERROR_SUCCESS;
    if (dnsRecord != nullptr) {
      if (status == ERROR_SUCCESS) {
        try {
          usable = readBrowseRecords(dnsRecord, result);
        } catch (...) {
          // A name that would not convert. An exception must not unwind into
          // Windows' thread.
          usable = false;
        }
      }
      DnsRecordListFree(dnsRecord, DnsFreeRecordList);
    }
    if (!usable) {
      return;
    }
    BonsoirAction::postToPlatformThread(contextToken(context), [result = std::move(result)](BonsoirAction &action) {
      static_cast<BonsoirDiscovery &>(action).onBrowseResult(result);
    });
  }

  // Runs on a Windows thread. Copies, frees, posts; touches no discovery.
  void resolveCallback(DWORD status, PVOID context, PDNS_SERVICE_INSTANCE serviceInstance) {
    ResolveResult result{status, contextResolveId(context)};
    if (serviceInstance != nullptr) {
      try {
        readServiceInstance(serviceInstance, result);
      } catch (...) {
        // Reported as a resolve with no usable instance.
        result.named = false;
        result.hasInstance = false;
      }
      DnsServiceFreeInstance(serviceInstance);
    }
    BonsoirAction::postToPlatformThread(contextToken(context), [result = std::move(result)](BonsoirAction &action) {
      static_cast<BonsoirDiscovery &>(action).onResolveResult(result);
    });
  }
}  // namespace bonsoir_windows
