# encoding: ascii-8bit

# Copyright 2014 Ball Aerospace & Technologies Corp.
# All Rights Reserved.
#
# This program is free software; you can modify and/or redistribute it
# under the terms of the GNU General Public License
# as published by the Free Software Foundation; version 3 with
# attribution addendums as found in the LICENSE.txt

require 'cosmos'
require 'cosmos/interfaces/tcpip_client_interface'

class PacketInterface < Cosmos::TcpipClientInterface
  def initialize(hostname, port, write_timeout = 10.0, read_timeout = nil)
    super(hostname, port, port, write_timeout, read_timeout, 'LENGTH', 0, 32, 4, 1, 'BIG_ENDIAN', 4)
  end

  def pre_write_packet(packet)
    [packet.length].pack('N') << packet.buffer
  end
end
