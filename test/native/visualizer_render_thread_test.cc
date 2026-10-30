// SPDX-License-Identifier: AGPL-3.0-only
#include "../../shared/visualization/render_thread.h"
#include <iostream>
using namespace plezy::visualization;
namespace {
struct Gate { std::mutex mutex; std::condition_variable condition; bool started=false, release=false; };
void Require(bool condition) { if (!condition) throw std::runtime_error("Render thread regression failed."); }
}
int main() {
  try {
    using Clock=std::chrono::steady_clock;
    auto gate=std::make_shared<Gate>();
    auto payload=std::make_shared<int>(42);
    std::weak_ptr<int> lifetime=payload;
    RenderThread blocked([gate,payload] {
      std::unique_lock<std::mutex> lock(gate->mutex);
      gate->started=true; gate->condition.notify_all();
      gate->condition.wait(lock,[&] { return gate->release; });
      Require(*payload==42); // State must survive host teardown.
    });
    payload.reset();
    { std::unique_lock<std::mutex> lock(gate->mutex);
      Require(gate->condition.wait_for(lock,std::chrono::seconds(5),[&] { return gate->started; })); }
    const auto start=Clock::now();
    Require(!blocked.Join());
    Require(!blocked.Join()); // A detached worker is not a completed worker.
    Require(Clock::now()-start<std::chrono::seconds(2));
    Require(!lifetime.expired());
    bool rejected=false;
    try { RenderThread forbidden([] {}); } catch (const std::runtime_error&) { rejected=true; }
    Require(rejected);
    { std::lock_guard<std::mutex> lock(gate->mutex); gate->release=true; }
    gate->condition.notify_all();
    bool recovered=false;
    const auto deadline=Clock::now()+std::chrono::seconds(5);
    while (Clock::now()<deadline) {
      try { RenderThread next([] {}); next.Join(); recovered=true; break; }
      catch (const std::runtime_error&) { std::this_thread::sleep_for(std::chrono::milliseconds(1)); }
    }
    Require(recovered && lifetime.expired());
    Require(blocked.Join()); // Completion is observable after quarantine/recovery.
    std::cout << "Render thread lifetime regressions passed\n";
  } catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}
