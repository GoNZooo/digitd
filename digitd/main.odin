package digitd

import "core:fmt"
import "core:net"
import "core:mem"
import "core:mem/virtual"
import "core:runtime"
import "core:thread"
import "core:time"

ClientData :: struct {
  socket: net.TCP_Socket,
}

main :: proc() {
  main_arena := virtual.Arena{}
  alloc_error := virtual.arena_init_static(&main_arena, 5 * 1024 * 1024)
  main_allocator := virtual.arena_allocator(&main_arena)
  context.allocator = main_allocator
  if alloc_error != nil {
    fmt.panicf("Failed to allocate memory for main arena: %v\n", alloc_error)
  }

  pool := thread.Pool{}
  thread.pool_init(&pool, main_allocator, 4)
  defer thread.pool_finish(&pool)

  thread.pool_start(&pool)

  listen_socket, network_error := net.listen_tcp(
    net.Endpoint{address = net.IP4_Address([4]u8{127, 0, 0, 1}), port = 1079},
  )
  if network_error != nil {
    fmt.panicf("Failed to listen on port 1079: %v\n", network_error)
  }
  set_sockopt_error := net.set_option(listen_socket, net.Socket_Option.Reuse_Address, true)
  if set_sockopt_error != nil {
    fmt.panicf("Failed to set socket option: %v\n", set_sockopt_error)
  }
  set_sockopt_error = net.set_option(
    listen_socket,
    net.Socket_Option.Receive_Timeout,
    time.Millisecond * 100,
  )
  if set_sockopt_error != nil {
    fmt.panicf("Failed to set socket option: %v\n", set_sockopt_error)
  }

  running := true
  for running {
    client_socket, _, accept_error := net.accept_tcp(listen_socket)
    if accept_error != nil {
      fmt.panicf("Failed to accept connection: %v\n", accept_error)
    }

    client_arena := virtual.Arena{}
    alloc_error = virtual.arena_init_static(&client_arena, 1024)
    if alloc_error != nil {
      fmt.panicf("Failed to allocate memory for client arena: %v\n", alloc_error)
    }
    client_allocator := virtual.arena_allocator(&client_arena)
    client_data := new(ClientData, client_allocator)
    client_data.socket = client_socket

    client_task := thread.Task{}
    client_task.procedure = handle_connection
    client_task.allocator = client_allocator
    client_task.data = client_data
  }
}

handle_connection :: proc(task: thread.Task) {
  data := transmute(^ClientData)task.data
  fmt.printf("Handling connection with %v\n", data)
}
