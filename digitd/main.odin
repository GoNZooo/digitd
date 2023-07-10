package digitd

import "core:net"
import "core:strconv"
import "core:log"
import "core:os"
import "core:mem"
import "core:mem/virtual"
import "core:runtime"
import "core:thread"
import "core:time"
import "core:strings"
import "core:path/filepath"

ClientData :: struct {
  socket:         net.TCP_Socket,
  allocator:      runtime.Allocator,
  main_allocator: runtime.Allocator,
  log_level:      log.Level,
}

UserListError :: union {
  mem.Allocator_Error,
  EnvironmentVariableNotFound,
  FileReadError,
}

EnvironmentVariableNotFound :: struct {
  key: string,
}

FileReadError :: struct {
  path: string,
}

InfoStringError :: union #shared_nil {
  mem.Allocator_Error,
  UserListError,
}

get_user_file_path :: proc(
  username: string,
  subpath: string,
  allocator := context.allocator,
) -> (
  path: string,
  error: mem.Allocator_Error,
) {
  return strings.concatenate({"/home/", username, "/.local/share/digitd/", subpath}, allocator)
}

get_info_file_path :: proc(
  username: string,
  allocator := context.allocator,
) -> (
  path: string,
  error: mem.Allocator_Error,
) {
  return get_user_file_path(username, "info", allocator)
}

get_plan_file_path :: proc(
  username: string,
  allocator := context.allocator,
) -> (
  path: string,
  error: mem.Allocator_Error,
) {
  return get_user_file_path(username, "plan", allocator)
}

get_project_file_path :: proc(
  username: string,
  allocator := context.allocator,
) -> (
  path: string,
  error: mem.Allocator_Error,
) {
  return get_user_file_path(username, "project", allocator)
}

get_users :: proc(allocator := context.allocator) -> (users_data: string, error: UserListError) {
  home_folder := os.get_env("HOME", allocator)
  if home_folder == "" {
    return "", EnvironmentVariableNotFound{key = "HOME"}
  }

  users_file_path := filepath.join({home_folder, ".local/share/digitd/users"}, allocator)
  defer delete(users_file_path)
  users_file_data, read_ok := os.read_entire_file_from_filename(users_file_path, allocator)
  defer delete(users_file_data)
  if !read_ok {
    return "", FileReadError{path = users_file_path}
  }

  cloned := strings.clone_from_bytes(users_file_data, allocator) or_return

  return cloned, nil
}

main :: proc() {
  log_level := log.Level.Info
  when ODIN_DEBUG {log_level = log.Level.Debug}
  context.logger = log.create_console_logger(ident = "main", lowest = log_level)
  log.infof("Log level: %v", log_level)

  args := os.args
  if len(args) < 2 {
    log.panicf("Usage: %s <port>", args[0])
  }
  ready := false

  port, parse_ok := strconv.parse_int(args[1], base = 10)
  if !parse_ok {
    log.panicf("Failed to parse port number: '%s'", args[1])
  }

  run_server(port, &ready, log_level)
}

run_server :: proc(port: int, ready: ^bool, log_level: log.Level, logger := context.logger) {
  context.logger = logger
  main_arena := virtual.Arena{}
  alloc_error := virtual.arena_init_static(&main_arena, 10 * 1024 * 1024)
  main_allocator := virtual.arena_allocator(&main_arena)
  context.allocator = main_allocator
  if alloc_error != nil {
    log.panicf("Failed to allocate memory for main arena: %v", alloc_error)
  }

  pool := thread.Pool{}
  thread.pool_init(&pool, main_allocator, 8)
  defer thread.pool_finish(&pool)

  thread.pool_start(&pool)

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
  ready^ = true

  running := true
  for running {
    client_socket, _, accept_error := net.accept_tcp(listen_socket)
    if accept_error == net.Accept_Error.Would_Block {
      continue
    } else if accept_error != nil {
      log.panicf("Failed to accept connection: %v", accept_error)
    }

    client_arena := virtual.Arena{}
    alloc_error = virtual.arena_init_static(&client_arena, 10 * 1024)
    if alloc_error != nil {
      log.panicf("Failed to allocate memory for client arena: %v", alloc_error)
    }
    client_allocator := virtual.arena_allocator(&client_arena)
    client_data := new(ClientData, client_allocator)
    client_data.socket = client_socket
    client_data.main_allocator = main_allocator
    client_data.allocator = client_allocator
    client_data.log_level = log_level

    thread.pool_add_task(&pool, client_allocator, handle_connection, client_data)
  }
}

handle_connection :: proc(task: thread.Task) {
  data := cast(^ClientData)task.data
  context.logger = log.create_console_logger(ident = "client", lowest = data.log_level)
  log.debugf("Handling connection")
  log.debugf("ClientData: %v", data)
  context.allocator = data.allocator
  defer free(data, data.main_allocator)
  defer free_all(data.allocator)
  defer net.close(data.socket)

  recv_buffer: [1024]u8
  send_buffer: [4096]u8

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
      log.infof("Connection closed")
      running = false
      continue
    }

    received_slice := recv_buffer[:bytes_received]
    info_string, handle_error := get_info_string(received_slice, data.allocator)
    if handle_error != nil {
      log.errorf("Failed to get info string: %v", handle_error)
      continue
    }

    copy(send_buffer[:], info_string)
    sent_bytes, send_error := net.send_tcp(data.socket, send_buffer[:len(info_string)])
    for sent_bytes < len(info_string) && send_error == nil {
      sent_bytes, send_error = net.send_tcp(data.socket, send_buffer[sent_bytes:len(info_string)])
    }
    if send_error != nil {
      log.errorf("Failed to send data: %v", send_error)
      running = false
      continue
    }
    running = false
  }

  log.debugf("Closing socket")
}

get_info_string :: proc(
  request_slice: []u8,
  allocator := context.allocator,
) -> (
  info_string: string,
  error: InfoStringError,
) {
  info_string_builder := strings.builder_make_none(allocator) or_return
  raw_request := strings.clone_from_bytes(request_slice, allocator) or_return
  defer delete(raw_request)
  request := strings.trim_right(raw_request, "\r\n ")
  log.debugf("Request: '%s' (%d bytes)", request, len(request))
  words := strings.split(request, " ", allocator) or_return
  defer delete(words)

  extra_info := false
  if len(words) >= 1 && words[0] == "/W" {
    extra_info = true
    log.debugf("Extra info requested")
    words = words[1:]
  }

  if len(words) == 0 || len(words) == 1 && words[0] == "" {
    return get_users(allocator)
  }

  for username in words {
    build_user_info(username, &info_string_builder)
  }

  return strings.to_string(info_string_builder), nil
}

build_user_info :: proc(
  username: string,
  builder: ^strings.Builder,
  allocator := context.allocator,
  logger := context.logger,
) -> (
  error: mem.Allocator_Error,
) {
  strings.write_string(builder, "= ")
  strings.write_string(builder, username)
  strings.write_string(builder, " =\n\n")
  info_file_path := get_info_file_path(username, allocator) or_return
  project_file_path := get_project_file_path(username, allocator) or_return
  plan_file_path := get_plan_file_path(username, allocator) or_return

  info_file, info_ok := os.read_entire_file_from_filename(info_file_path, allocator)
  if info_ok {
    strings.write_bytes(builder, info_file)
  } else {
    log.warnf("Failed to read info file for user '%s' ('%s')", username, info_file_path)
  }

  project_file, project_ok := os.read_entire_file_from_filename(project_file_path)
  if project_ok {
    strings.write_string(builder, "\n\n= Project =\n\n")
    strings.write_bytes(builder, project_file)
  } else {
    log.warnf("Failed to read project file for user '%s' ('%s')", username, project_file_path)
  }

  plan_file, plan_ok := os.read_entire_file_from_filename(plan_file_path)
  if plan_ok {
    strings.write_string(builder, "\n\n= Plan =\n\n")
    strings.write_bytes(builder, plan_file)
  } else {
    log.warnf("Failed to read plan file for user '%s' ('%s')", username, plan_file_path)
  }

  strings.write_string(builder, "\r\n")

  return nil
}
