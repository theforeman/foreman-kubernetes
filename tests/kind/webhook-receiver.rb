#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'socket'

STDOUT.sync = true
server = TCPServer.new('0.0.0.0', 9999)

shutdown = proc do
  server.close
  exit
end
trap('INT', &shutdown)
trap('TERM', &shutdown)

loop do
  socket = server.accept
  request_line = socket.gets&.strip
  next socket.close unless request_line

  headers = {}
  while (line = socket.gets)
    line = line.strip
    break if line.empty?

    name, value = line.split(':', 2)
    headers[name.downcase] = value.to_s.strip
  end
  body = socket.read(headers.fetch('content-length', '0').to_i)
  path = request_line.split.fetch(1)
  status = path == '/failure' ? 503 : 204
  reason = status == 503 ? 'Service Unavailable' : 'No Content'

  puts JSON.generate(
    request: request_line,
    path: path,
    status: status,
    content_type: headers['content-type'],
    body: body
  )
  socket.write("HTTP/1.1 #{status} #{reason}\r\nConnection: close\r\nContent-Length: 0\r\n\r\n")
ensure
  socket&.close
end
