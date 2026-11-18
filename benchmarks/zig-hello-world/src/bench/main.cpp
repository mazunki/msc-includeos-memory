#include <os>
#include <service>

extern "C" int zig_add(int a, int b);
extern "C" int zig_alloc_roundtrip();

void Service::start(const std::string&) {
  std::println("hello from the zig<->includeos bridge!");
  std::println("zig_add(2, 40) = {}", zig_add(2, 40));

  const int alloc_result = zig_alloc_roundtrip();
  std::println("zig_alloc_roundtrip() = {} ({})", alloc_result, alloc_result == 0 ? "PASS" : "FAIL");

  os::shutdown();
}
