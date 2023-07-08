package digitd

import "core:net"
import "core:log"
// import "core:mem"
import "core:mem/virtual"
import "core:runtime"
import "core:thread"
import "core:time"

ClientData :: struct {
  socket:         net.TCP_Socket,
  allocator:      runtime.Allocator,
  main_allocator: runtime.Allocator,
}

main :: proc() {
  context.logger = log.create_console_logger(ident = "main")

  main_arena := virtual.Arena{}
  alloc_error := virtual.arena_init_static(&main_arena, 5 * 1024 * 1024)
  main_allocator := virtual.arena_allocator(&main_arena)
  context.allocator = main_allocator
  if alloc_error != nil {
    log.panicf("Failed to allocate memory for main arena: %v", alloc_error)
  }

  pool := thread.Pool{}
  thread.pool_init(&pool, main_allocator, 4)
  defer thread.pool_finish(&pool)

  thread.pool_start(&pool)
  port := 1079

  listen_socket, network_error := net.listen_tcp(
    net.Endpoint{address = net.IP4_Address([4]u8{127, 0, 0, 1}), port = port},
  )
  if network_error != nil {
    log.panicf("Failed to listen on port %d: %v", port, network_error)
  }
  set_sockopt_error := net.set_option(listen_socket, net.Socket_Option.Reuse_Address, true)
  if set_sockopt_error != nil {
    log.panicf("Failed to set socket option: %v", set_sockopt_error)
  }
  set_sockopt_error = net.set_option(
    listen_socket,
    net.Socket_Option.Receive_Timeout,
    time.Millisecond * 100,
  )
  if set_sockopt_error != nil {
    log.panicf("Failed to set socket option: %v", set_sockopt_error)
  }

  running := true
  for running {
    client_socket, _, accept_error := net.accept_tcp(listen_socket)
    if accept_error == net.Accept_Error.Would_Block {
      continue
    } else if accept_error != nil {
      log.panicf("Failed to accept connection: %v", accept_error)
    }
    log.debugf("Accepted connection: %d", client_socket)

    client_arena := virtual.Arena{}
    alloc_error = virtual.arena_init_static(&client_arena, 1024)
    if alloc_error != nil {
      log.panicf("Failed to allocate memory for client arena: %v", alloc_error)
    }
    client_allocator := virtual.arena_allocator(&client_arena)
    client_data := new(ClientData, client_allocator)
    client_data.socket = client_socket
    client_data.main_allocator = main_allocator

    thread.pool_add_task(&pool, client_allocator, handle_connection, client_data)
  }
}

handle_connection :: proc(task: thread.Task) {
  context.logger = log.create_console_logger()
  log.debugf("Handling connection")
  data := cast(^ClientData)task.data
  context.allocator = data.allocator
  log.debugf("ClientData: %v", data)

  recv_buffer: [1024]u8
  // send_buffer: [2048]u8

  running := true
  for running {
    bytes_received, recv_error := net.recv_tcp(data.socket, recv_buffer[:])
    if recv_error == net.TCP_Recv_Error.Timeout {
      continue
    } else if recv_error != nil {
      log.errorf("Failed to receive data: %v", recv_error)
      running = false
      continue
    } else if bytes_received == 0 {
      log.errorf("Connection closed")
      running = false
      continue
    }
    log.debugf("Received %d bytes", bytes_received)

    received_slice := recv_buffer[:bytes_received]
    log.debugf("Received slice: %s", received_slice)
  }

  free(data, data.main_allocator)
}
