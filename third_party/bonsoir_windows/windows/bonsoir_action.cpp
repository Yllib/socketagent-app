#pragma once

#include "bonsoir_action.h"

#include <flutter/binary_messenger.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/standard_method_codec.h>

#include <map>
#include <vector>

using namespace flutter;

namespace bonsoir_windows {
  namespace {
    constexpr wchar_t kMessageWindowClassName[] = L"BonsoirWindowsEventMessageWindow";
    std::once_flag gRegisterMessageWindowClassFlag;

    // A live action's message window and the tasks other threads have posted
    // to it.
    struct Inbox {
      HWND window;
      std::vector<std::function<void(BonsoirAction &)>> tasks;
    };

    // Guards gInboxes. Never held across a DNS API call or a task.
    std::mutex gInboxesMutex;
    std::map<uint32_t, Inbox> gInboxes;
    std::atomic<uint32_t> gNextToken{1};
  }

  BonsoirAction::BonsoirAction(
    std::string _action,
    const std::map<std::string, std::string> _logMessages,
    int _id,
    bool _printLogs,
    BinaryMessenger *_binaryMessenger
  )
    : action(_action),
      logMessages(_logMessages),
      id(_id),
      token(gNextToken.fetch_add(1)),
      eventChannel(std::make_unique<EventChannel<EncodableValue>>(_binaryMessenger, "fr.skyost.bonsoir." + _action + "." + std::to_string(id), &StandardMethodCodec::GetInstance())),
      printLogs(_printLogs) {
    RegisterMessageWindowClass();
    messageWindow = CreateWindowExW(
      0,
      kMessageWindowClassName,
      L"",
      0,
      0,
      0,
      0,
      0,
      HWND_MESSAGE,
      nullptr,
      GetModuleHandle(nullptr),
      this
    );
    {
      std::scoped_lock lock{gInboxesMutex};
      gInboxes[token] = Inbox{messageWindow, {}};
    }

    eventChannel->SetStreamHandler(
      std::make_unique<StreamHandlerFunctions<EncodableValue>>(
        [this](const EncodableValue *arguments, std::unique_ptr<EventSink<EncodableValue>> &&events)
          -> std::unique_ptr<StreamHandlerError<EncodableValue>> {
          eventSink = std::move(events);
          processEventQueue();
          return nullptr;
        },
        [this](const EncodableValue *arguments)
          -> std::unique_ptr<StreamHandlerError<EncodableValue>> {
          eventSink = nullptr;
          if (shouldDisposeAfterStreamCancel && messageWindow) {
            PostMessage(messageWindow, disposeAfterStreamCancelMessage, 0, 0);
          }
          return nullptr;
        }
      )
    );
  }

  void BonsoirAction::start() {
    state.store(1, std::memory_order_release);
  }

  bool BonsoirAction::isRunning() {
    return state.load(std::memory_order_acquire) == 1;
  }

  void BonsoirAction::stop() {
    state.store(0, std::memory_order_release);
  }

  void BonsoirAction::dispose() {
    stop();
    shouldDisposeAfterStreamCancel = false;
    disposeAfterStreamCancelCallback = nullptr;
    {
      // Before the window goes, so nothing is posted to a dead handle.
      std::scoped_lock lock{gInboxesMutex};
      gInboxes.erase(token);
    }
    if (messageWindow) {
      DestroyWindow(messageWindow);
      messageWindow = nullptr;
    }
    if (eventChannel) {
      eventChannel->SetStreamHandler(nullptr);
      eventChannel = nullptr;
    }
  }

  void BonsoirAction::disposeAfterStreamCancel(std::function<void(int)> callback) {
    shouldDisposeAfterStreamCancel = true;
    disposeAfterStreamCancelCallback = callback;
    if (!eventSink && messageWindow) {
      PostMessage(messageWindow, disposeAfterStreamCancelMessage, 0, 0);
    }
  }

  void BonsoirAction::onEvent(std::shared_ptr<EventObject> eventObjectPtr, std::list<std::string> parameters) {
    log(eventObjectPtr->message, parameters);
    {
      std::scoped_lock lock{mutex};
      eventQueue.push(std::move(eventObjectPtr));
    }
    if (messageWindow) {
      PostMessage(messageWindow, processEventQueueMessage, 0, 0);
    }
  }

  void BonsoirAction::postToPlatformThread(uint32_t token, std::function<void(BonsoirAction &)> task) {
    std::scoped_lock lock{gInboxesMutex};
    auto inbox = gInboxes.find(token);
    if (inbox == gInboxes.end() || !inbox->second.window) {
      return;
    }
    inbox->second.tasks.push_back(std::move(task));
    PostMessage(inbox->second.window, runPostedTasksMessage, 0, 0);
  }

  void BonsoirAction::runPostedTasks() {
    std::vector<std::function<void(BonsoirAction &)>> tasks;
    {
      std::scoped_lock lock{gInboxesMutex};
      auto inbox = gInboxes.find(token);
      if (inbox == gInboxes.end()) {
        return;
      }
      tasks.swap(inbox->second.tasks);
    }
    for (auto const &task : tasks) {
      task(*this);
    }
  }

  void BonsoirAction::log(std::string message, std::list<std::string> parameters) {
    if (printLogs) {
      std::cout << ("[" + action + "] [" + std::to_string(id) + "] " + format(message, parameters)) << std::endl;
    }
  }

  std::string BonsoirAction::format(std::string message, std::list<std::string> parameters) {
    std::string result = message;
    for (auto const &parameter : parameters) {
      size_t position = result.find("%s");
      if (position != std::string::npos) {
        result.replace(position, 2, parameter);
      }
    }
    return result;
  }

  void BonsoirAction::processEventQueue() {
    if (!eventSink) {
      return;
    }
    std::scoped_lock lock{mutex};
    while (!eventQueue.empty()) {
      eventQueue.front()->process(this);
      eventQueue.pop();
    }
  }

  void BonsoirAction::RegisterMessageWindowClass() {
    std::call_once(gRegisterMessageWindowClassFlag, []() {
      WNDCLASSW windowClass{};
      windowClass.lpfnWndProc = BonsoirAction::MessageWindowProc;
      windowClass.hInstance = GetModuleHandle(nullptr);
      windowClass.lpszClassName = kMessageWindowClassName;
      RegisterClassW(&windowClass);
    });
  }

  LRESULT CALLBACK BonsoirAction::MessageWindowProc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
    if (message == WM_NCCREATE) {
      const auto createStruct = reinterpret_cast<CREATESTRUCT*>(lparam);
      SetWindowLongPtr(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(createStruct->lpCreateParams));
      return TRUE;
    }

    auto action = reinterpret_cast<BonsoirAction*>(GetWindowLongPtr(hwnd, GWLP_USERDATA));
    if (message == processEventQueueMessage && action) {
      action->processEventQueue();
      return 0;
    }
    if (message == runPostedTasksMessage && action) {
      action->runPostedTasks();
      return 0;
    }
    if (message == disposeAfterStreamCancelMessage && action) {
      auto callback = action->disposeAfterStreamCancelCallback;
      if (callback) {
        callback(action->id);
      }
      return 0;
    }

    return DefWindowProc(hwnd, message, wparam, lparam);
  }

  EventObject::EventObject(std::string _message)
    : message(_message) {}

  SuccessObject::SuccessObject(std::string _id, std::string _message, std::shared_ptr<BonsoirService> _service)
    : EventObject(_message), id(_id), service(_service) {}

  void SuccessObject::process(BonsoirAction *action) {
    action->eventSink->Success(toEncodable());
  }

  EncodableMap SuccessObject::toEncodable() const {
    auto result = EncodableMap{{EncodableValue("id"), EncodableValue(id)}};
    if (service) {
      result.insert({EncodableValue("service"), service->toEncodable()});
    }
    return result;
  }

  ErrorObject::ErrorObject(std::string _message, EncodableValue _details)
    : EventObject(_message), details(_details) {}

  void ErrorObject::process(BonsoirAction *action) {
    action->eventSink->Error(action->action + "Error", message, details);
  }
}  // namespace bonsoir_windows
