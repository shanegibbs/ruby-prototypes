require 'colorize'
require 'socket'
require 'timeout'

x11_server = '127.0.0.1'
x11_server_port = 6002

listen_port = 6003

def connect_to(host, port, timeout=nil)
  addr = Socket.getaddrinfo(host, nil)
  sock = Socket.new(Socket.const_get(addr[0][0]), Socket::SOCK_STREAM, 0)

  if timeout
    secs = Integer(timeout)
    usecs = Integer((timeout - secs) * 1_000_000)
    optval = [secs, usecs].pack('l_2')
    sock.setsockopt Socket::SOL_SOCKET, Socket::SO_RCVTIMEO, optval
    sock.setsockopt Socket::SOL_SOCKET, Socket::SO_SNDTIMEO, optval
  end
  sock.connect(Socket.pack_sockaddr_in(port, addr[0][3]))
  sock
end

class Packet

  attr_accessor :data

  def initialize(data)
    @data = data
  end

  def get_card32(idx)
    a = @data[idx + 0].ord
    b = @data[idx + 1].ord
    c = @data[idx + 2].ord
    d = @data[idx + 3].ord
    a + (b << 8) + (c << 16) + (d << 24)
  end

  def get_card16(idx)
    a = @data[idx + 0].ord
    b = @data[idx + 1].ord
    a + (b << 8)
  end

  def get_card8(idx)
    @data[idx].ord
  end

end

def client_send(seq, client, x11)

  header_size = 4
  pkt = Packet.new client.recv(header_size)
  op_code = pkt.get_card8(0)
  length = pkt.get_card16(2)
  #puts "#{seq} Client sent header"

  add_length = (length * 4) - header_size

  # puts "add_length=#{add_length}, op_code=#{op_code}"
  pkt.data.concat client.recv add_length if add_length > 0
  # puts "add_length=#{add_length}, op_code=#{op_code} done"

  x11.send pkt.data, 0
  puts "#{seq} Client send, length=#{length}, op_code=#{op_code}"

end

def dump_array(data)
  output = "\nlength=#{data.length}\n"
  (0..data.length-1).each do |i|
    val = data[i].ord
    output += "[#{i.to_s}]=#{val}".ljust(12)
    output += "\n" if i % 4 == 3
  end
  output += "\n"
  puts output
end

def client_recv(client, x11)

  begin
    header_size = 8
    pkt = Packet.new x11.recv(header_size)
    reply = pkt.get_card8 0
    seq = pkt.get_card16 2
    length = pkt.get_card32 4

    total_length = 32 + (length * 4)
    if reply == 0
      puts 'is error msg'
      total_length = 32
    end

    add_length = total_length - header_size

    # dump_array pkt.data

    puts "#{seq} Client rcvd header, length=#{length}, total_length=#{total_length}, add_length=#{add_length}"

    start_time = Time.now.getutc
    last_need_add_length = 0
    need_add_length = add_length
    while need_add_length > 0
      data_changed = last_need_add_length != need_add_length

      begin
        add_data = x11.recv_nonblock need_add_length
        pkt.data.concat add_data
      rescue Errno::EAGAIN => e
        if Time.now.getutc - start_time > 3

          dump_array pkt.data

          raise 'Took too long to receive data'
        end
      end
      puts "#{seq} received #{pkt.data.length}/#{total_length}" if data_changed

      need_add_length = total_length - pkt.data.length
      last_need_add_length = need_add_length
    end

    puts "#{seq} Client rcvd"
    dump_array pkt.data

    client.send pkt.data, 0
    puts "#{seq} Client rcvd passed on"

  rescue Exception => e
    puts "\n#{e.class} - #{e.message}".red
    puts e.backtrace.inspect
    exit
  end
end

def test_equal(expected, actual)
  if expected != actual
    raise "Expected '#{expected}', but was '#{actual}'"
  end
end

pkt = Packet.new [1, 0, 2, 1]
test_equal 1, pkt.get_card16(0)
test_equal 258, pkt.get_card16(2)
test_equal 16908289, pkt.get_card32(0)

puts '* All tests passed'.green

# Rcv xConnClientPrefix
# Snd xConnSetupPrefix
# Snd xConnSetup

sz_xConnClientPrefix = 12
sz_xConnSetupPrefix = 8
sz_xConnSetup = 32

server = TCPServer.new listen_port
loop do
  Thread.start(server.accept) do |client|
    puts 'Client connected'

    pkt = client.recv(sz_xConnClientPrefix)
    puts 'got client conn prefix'

    x11 = connect_to(x11_server, x11_server_port, 2)
    puts 'connected to x11'
    x11.send pkt, 0
    puts 'sent client conn prefix to x11'

    pkt = Packet.new x11.recv(sz_xConnSetupPrefix + sz_xConnSetup)
    length = pkt.get_card16 6
    puts "length=#{length}"

    add_data = x11.recv(length * 4)
    pkt.data.concat add_data

    client.send pkt.data, 0
    puts 'relayed conn setup pkt'

    threads = []
    threads << Thread.new {
      seq = 1
      while true
        client_send seq, client, x11
        seq += 1
      end
    }
    threads << Thread.new {
      while true
        client_recv client, x11
      end
    }
    threads.each { |thr| thr.join }

    x11.close

    puts 'done'
    client.close

    exit
  end
end
