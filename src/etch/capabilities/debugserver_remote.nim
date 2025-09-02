# debugserver_remote.nim
# TCP-based remote debug server for embedded Etch scenarios
# Allows debugging Etch scripts running inside C/C++ applications

import std/[json, net, os, times, nativesockets, strutils]
import ../core/vm_types
import ./debugserver


type
  RemoteDebugServer* = ref object
    server*: DebugServer  # Reuse existing debug server logic
    socket*: Socket
    clientSocket*: Socket
    port*: int
    listening*: bool
    connected*: bool


proc newRemoteDebugServer*(program: BytecodeProgram, sourceFile: string, port: int = 9823): RemoteDebugServer =
  ## Create a new remote debug server that listens on a TCP port
  ## program: Compiled Etch bytecode program
  ## sourceFile: Source file path for debug information
  ## port: TCP port to listen on (default: 9823)

  var remoteServer = RemoteDebugServer(
    server: newDebugServer(program, sourceFile),
    socket: newSocket(),
    clientSocket: nil,
    port: port,
    listening: false,
    connected: false
  )

  # Override the debug server's event handler to send events over TCP socket
  # This captures events like 'stopped', 'terminated', 'output' etc.
  remoteServer.server.debugger.onDebugEvent = proc(event: string, data: JsonNode) =
    if remoteServer.connected and remoteServer.clientSocket != nil:
      let eventMsg = %*{
        "type": "event",
        "event": event,
        "body": data
      }
      stderr.writeLine("DEBUG: Sending event to client: " & event)
      stderr.flushFile()

      try:
        let msgStr = $eventMsg & "\n"
        remoteServer.clientSocket.send(msgStr)
      except OSError as e:
        stderr.writeLine("ERROR: Failed to send event: " & e.msg)
        stderr.flushFile()
        remoteServer.connected = false

  result = remoteServer


proc startListening*(server: RemoteDebugServer): bool =
  ## Start listening for debug connections on the configured port
  ## Returns: true on success, false on failure
  try:
    server.socket.setSockOpt(OptReuseAddr, true)
    server.socket.bindAddr(Port(server.port), "127.0.0.1")
    server.socket.listen()
    server.listening = true

    stderr.writeLine("DEBUG: Remote debug server listening on port " & $server.port)
    stderr.flushFile()
    return true
  except OSError as e:
    stderr.writeLine("ERROR: Failed to start debug server on port " & $server.port & ": " & e.msg)
    stderr.flushFile()
    return false


proc acceptConnection*(server: RemoteDebugServer, timeoutMs: int = 0): bool =
  ## Accept a connection from a debug client (VSCode)
  ## timeoutMs: Timeout in milliseconds (0 = block indefinitely)
  ## Returns: true if connection accepted, false on timeout or error
  try:
    if timeoutMs > 0:
      # Non-blocking accept with timeout
      server.socket.getFd().setBlocking(false)
      let startTime = epochTime()

      while true:
        try:
          # Don't create socket beforehand - accept() does it
          new(server.clientSocket)
          server.socket.accept(server.clientSocket)
          server.connected = true

          stderr.writeLine("DEBUG: Remote debug client connected")
          stderr.flushFile()

          # Set sockets back to blocking mode
          server.socket.getFd().setBlocking(true)
          server.clientSocket.getFd().setBlocking(true)
          return true

        except OSError as e:
          # Check if it's a "would block" error (no connection yet)
          if "Resource temporarily unavailable" in e.msg or "would block" in e.msg.toLowerAscii() or "Bad file descriptor" in e.msg:
            # Check timeout
            let elapsed = (epochTime() - startTime) * 1000.0
            if elapsed >= timeoutMs.float:
              stderr.writeLine("DEBUG: Connection timeout after " & $timeoutMs & "ms")
              stderr.flushFile()
              server.socket.getFd().setBlocking(true)
              return false

            # Sleep a bit before retrying
            sleep(100)  # Sleep for 100ms
            continue
          else:
            # Real error
            stderr.writeLine("ERROR: Failed to accept connection: " & e.msg)
            stderr.flushFile()
            server.socket.getFd().setBlocking(true)
            return false
    elif timeoutMs == 0:
      # Immediate non-blocking attempt
      server.socket.getFd().setBlocking(false)
      try:
        new(server.clientSocket)
        server.socket.accept(server.clientSocket)
        server.connected = true

        stderr.writeLine("DEBUG: Remote debug client connected")
        stderr.flushFile()

        server.socket.getFd().setBlocking(true)
        server.clientSocket.getFd().setBlocking(true)
        return true
      except OSError as e:
        if "Resource temporarily unavailable" in e.msg or "would block" in e.msg.toLowerAscii():
          server.socket.getFd().setBlocking(true)
          return false
        else:
          server.socket.getFd().setBlocking(true)
          stderr.writeLine("ERROR: Failed to accept connection: " & e.msg)
          stderr.flushFile()
          return false
    else:
      # Blocking accept
      new(server.clientSocket)
      server.socket.accept(server.clientSocket)
      server.connected = true

      stderr.writeLine("DEBUG: Remote debug client connected")
      stderr.flushFile()
      return true

  except OSError as e:
    stderr.writeLine("ERROR: Failed to accept connection: " & e.msg)
    stderr.flushFile()
    return false


proc tryAcceptConnection*(server: RemoteDebugServer): bool =
  ## Attempt to accept without blocking
  return server.acceptConnection(0)


proc forceTerminateExistingServer*(port: int, timeoutMs: int = 2000): bool =
  ## Attempt to terminate an already running Etch remote debug server on this port.
  ## Returns true if a server was contacted and asked to terminate.
  var client: Socket
  try:
    new(client)
    client.connect("127.0.0.1", Port(port))

    let terminateReq = %*{
      "seq": 9999,
      "type": "request",
      "command": "terminate",
      "arguments": {}
    }
    client.send($terminateReq & "\n")

    # Give the remote server a brief moment to shut down
    var waitMs = timeoutMs
    if waitMs <= 0:
      waitMs = 200
    if waitMs > 1000:
      waitMs = 1000
    sleep(waitMs)
    client.close()

    stderr.writeLine("DEBUG: Sent terminate to existing debug server on port " & $port)
    stderr.flushFile()
    return true
  except OSError as e:
    stderr.writeLine("DEBUG: Unable to terminate existing server on port " & $port & ": " & e.msg)
    stderr.flushFile()
  except:
    discard
  finally:
    if client != nil:
      try:
        client.close()
      except:
        discard
  return false


proc sendMessage*(server: RemoteDebugServer, message: JsonNode) =
  ## Send a JSON message to the connected debug client
  if not server.connected or server.clientSocket == nil:
    stderr.writeLine("ERROR: Cannot send message - no client connected")
    stderr.flushFile()
    return

  try:
    let msgStr = $message & "\n"
    server.clientSocket.send(msgStr)
  except OSError as e:
    stderr.writeLine("ERROR: Failed to send message: " & e.msg)
    stderr.flushFile()
    server.connected = false


proc receiveMessage*(server: RemoteDebugServer, timeoutMs: int = 0): JsonNode =
  ## Receive a JSON message from the connected debug client
  ## timeoutMs: Timeout in milliseconds (0 = block indefinitely)
  ## Returns: Parsed JSON message or nil on error/timeout
  if not server.connected or server.clientSocket == nil:
    stderr.writeLine("ERROR: Cannot receive message - no client connected")
    stderr.flushFile()
    return nil

  try:
    var line = ""

    if timeoutMs > 0:
      # Non-blocking receive with timeout
      server.clientSocket.getFd().setBlocking(false)
      let startTime = epochTime()

      while true:
        try:
          line = server.clientSocket.recvLine()
          if line.len == 0:
            # Connection closed
            stderr.writeLine("DEBUG: Client disconnected")
            stderr.flushFile()
            server.connected = false
            server.clientSocket.getFd().setBlocking(true)
            return nil

          # Set back to blocking mode and return result
          server.clientSocket.getFd().setBlocking(true)
          return parseJson(line)

        except OSError as e:
          # Check if it's a "would block" error
          if "Resource temporarily unavailable" in e.msg or "would block" in e.msg.toLowerAscii():
            # Check timeout
            let elapsed = (epochTime() - startTime) * 1000.0
            if elapsed >= timeoutMs.float:
              server.clientSocket.getFd().setBlocking(true)
              return nil

            # Sleep a bit before retrying
            sleep(100)
            continue
          else:
            # Real error
            stderr.writeLine("ERROR: Failed to receive message: " & e.msg)
            stderr.flushFile()
            server.connected = false
            server.clientSocket.getFd().setBlocking(true)
            return nil
    elif timeoutMs == 0:
      # Blocking receive
      line = server.clientSocket.recvLine()
      if line.len == 0:
        # Connection closed
        stderr.writeLine("DEBUG: Client disconnected")
        stderr.flushFile()
        server.connected = false
        return nil
    else:
      # Immediate non-blocking attempt
      server.clientSocket.getFd().setBlocking(false)
      try:
        line = server.clientSocket.recvLine()
        if line.len == 0:
          stderr.writeLine("DEBUG: Client disconnected")
          stderr.flushFile()
          server.connected = false
          server.clientSocket.getFd().setBlocking(true)
          return nil
      except OSError as e:
        if "Resource temporarily unavailable" in e.msg or "would block" in e.msg.toLowerAscii():
          server.clientSocket.getFd().setBlocking(true)
          return nil
        else:
          server.clientSocket.getFd().setBlocking(true)
          raise
      server.clientSocket.getFd().setBlocking(true)

    # Parse JSON
    return parseJson(line)

  except OSError as e:
    # Don't log EINTR as error - it's expected when C++ debugger pauses the process
    if "Interrupted system call" notin e.msg:
      stderr.writeLine("ERROR: Failed to receive message: " & e.msg)
      stderr.flushFile()
      server.connected = false
    # Re-raise EINTR so caller can retry
    raise
  except JsonParsingError as e:
    stderr.writeLine("ERROR: Failed to parse JSON: " & e.msg)
    stderr.flushFile()
    return nil


proc handleRequest*(server: RemoteDebugServer, request: JsonNode): JsonNode =
  ## Handle a debug request and return response
  ## This wraps the existing DebugServer.handleDebugRequest
  ## Note: Events are automatically sent via the onDebugEvent handler set in newRemoteDebugServer

  # Handle the request using existing debug server logic
  let response = handleDebugRequest(server.server, request)

  # Add request metadata
  if request.hasKey("seq"):
    response["request_seq"] = request["seq"]
  response["type"] = %"response"
  response["command"] = request["command"]

  return response


proc runMessageLoop*(server: RemoteDebugServer): bool =
  ## Run the main message loop, handling debug requests until disconnection
  ## Returns: true if loop exited normally, false on error

  stderr.writeLine("DEBUG: Starting remote debug message loop")
  stderr.flushFile()

  while server.connected:
    # Receive request from client (with retry on EINTR)
    var request: JsonNode = nil
    var retries = 0
    const maxRetries = 3

    while retries < maxRetries:
      try:
        request = server.receiveMessage(timeoutMs = 0)  # Blocking
        break  # Success
      except OSError as e:
        if "Interrupted system call" in e.msg and retries < maxRetries - 1:
          # EINTR - retry (happens when C++ debugger pauses the process)
          stderr.writeLine("DEBUG: Receive interrupted (EINTR), retrying...")
          stderr.flushFile()
          retries += 1
          sleep(10)  # Brief pause before retry
          continue
        else:
          # Other error or max retries
          stderr.writeLine("ERROR: Failed to receive message: " & e.msg)
          stderr.flushFile()
          request = nil
          break

    if request == nil:
      # Connection closed or error
      break

    stderr.writeLine("DEBUG: Received request: " & request["command"].getStr())
    stderr.flushFile()

    # Handle the request
    let response = server.handleRequest(request)

    # Send response
    server.sendMessage(response)

    # Check for disconnect/terminate
    let command = request["command"].getStr()
    if command == "disconnect" or command == "terminate":
      stderr.writeLine("DEBUG: Received " & command & " command, exiting message loop")
      stderr.flushFile()
      break

  stderr.writeLine("DEBUG: Remote debug message loop ended")
  stderr.flushFile()
  return true


proc disconnectClient*(server: RemoteDebugServer) =
  ## Disconnect the active debug client but keep listening socket alive
  if server.clientSocket != nil:
    try:
      server.clientSocket.close()
    except:
      discard
    server.clientSocket = nil
  server.connected = false


proc processRequests*(server: RemoteDebugServer, timeoutMs: int = 0,
                      untilResume: bool = false): bool =
  ## Incrementally process incoming debug requests.
  ## When untilResume=true, blocks until a continue/step request is received or the client disconnects.
  if server == nil or not server.connected or server.clientSocket == nil:
    return false

  var processedAny = false

  while true:
    var waitTime = timeoutMs
    if untilResume or processedAny:
      if timeoutMs > 0:
        waitTime = 0
      else:
        waitTime = timeoutMs

    var request: JsonNode = nil

    var retries = 0
    const maxRetries = 3

    while true:
      try:
        request = server.receiveMessage(waitTime)
        break
      except OSError as e:
        if "Interrupted system call" in e.msg and retries < maxRetries:
          retries.inc
          sleep(10)
          continue
        else:
          stderr.writeLine("ERROR: Failed to receive request: " & e.msg)
          stderr.flushFile()
          server.disconnectClient()
          return false

    if request == nil:
      return processedAny and not untilResume

    processedAny = true
    let response = server.handleRequest(request)
    server.sendMessage(response)

    let command = request["command"].getStr()

    if command == "disconnect" or command == "terminate":
      server.disconnectClient()
      return false

    if server.server.hostControlled and
       (command == "continue" or command == "next" or command == "stepIn" or command == "stepOut"):
      return true

    if not untilResume:
      return true

    # When waiting for resume, keep servicing requests until we see a resume command


proc close*(server: RemoteDebugServer) =
  ## Close the debug server and all connections
  server.disconnectClient()
  if server.socket != nil:
    try:
      server.socket.close()
    except:
      discard
    server.socket = nil

  server.connected = false
  server.listening = false

  stderr.writeLine("DEBUG: Remote debug server closed")
  stderr.flushFile()


proc isConnected*(server: RemoteDebugServer): bool =
  ## Check if a client is currently connected
  return server.connected and server.clientSocket != nil
