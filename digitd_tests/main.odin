package digitd_tests

import "core:testing"
import "core:log"
import "core:mem"
import "core:fmt"
import "core:os"
import "core:runtime"
// import "core:strings"
// import "core:slice"

import "../digitd"

TEST_count := 0
TEST_fail := 0

when ODIN_TEST {
  expect :: testing.expect
  log :: testing.log
} else {
  expect :: proc(t: ^testing.T, condition: bool, message: string, loc := #caller_location) {
    TEST_count += 1
    if !condition {
      TEST_fail += 1
      fmt.printf("[%v] %v\n", loc, message)
      return
    }
  }
}

expect_no_leaks :: proc(t: ^testing.T, allocator: mem.Tracking_Allocator) {
  expect(
    t,
    len(allocator.allocation_map) == 0,
    fmt.tprintf("len(allocator.allocation_map) != 0: %v\n", len(allocator.allocation_map)),
  )
  if len(allocator.allocation_map) != 0 {
    i := 0
    for _, allocation in allocator.allocation_map {
      fmt.printf("[%d] %v\n", i, allocation)
      i += 1
    }
  }
}

main :: proc() {
  context.logger = log.create_console_logger()

  t := testing.T{}

  test_true(&t)

  fmt.printf("%v\n\t%v/%v tests successful.\n", #location(), TEST_count - TEST_fail, TEST_count)
  if TEST_fail > 0 {
    os.exit(1)
  }
}

test_true :: proc(t: ^testing.T) {
  expect(t, true, "true is not true")
}
