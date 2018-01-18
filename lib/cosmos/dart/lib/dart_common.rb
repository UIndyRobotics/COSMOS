# encoding: ascii-8bit

# Copyright 2018 Ball Aerospace & Technologies Corp.
# All Rights Reserved.
#
# This program is free software; you can modify and/or redistribute it
# under the terms of the GNU General Public License
# as published by the Free Software Foundation; version 3 with
# attribution addendums as found in the LICENSE.txt

require File.expand_path('../../config/environment', __FILE__)
require 'cosmos/script'
require 'optparse'

# Autoload models here to remove problems loading within Cosmos namespace
Target
Packet
PacketLog
PacketLogEntry

# Implement methods common to DART (Data Archival Retrieval and Trending).
# Most of these methods handle accessing the DART database.
module DartCommon
  # @return [Integer] Maximimum byte size of strings in the database
  MAX_STRING_BYTE_SIZE = 191 # Works well with mysql utf8mb4 if we want to support mysql in the future
  # @return [Integer] Maximimum bit size of strings in the database
  MAX_STRING_BIT_SIZE = MAX_STRING_BYTE_SIZE * 8
  # @return [Integer] Maximum number of columns in a database table
  MAX_COLUMNS_PER_TABLE = 200
  # @return [Array<Symbol>] Data types which can be reduced over a time period.
  #   These data types will result in minute, hour, and daily database tables.
  REDUCED_TYPES = [:integer, :bigint, :decimal, :float]

  # Argument parser for the DART command line tools
  def self.handle_argv(parse = true)
    parser = OptionParser.new do |option_parser|
      option_parser.banner = "Usage: ruby #{option_parser.program_name} [options]"
      option_parser.separator("")

      # Create the help option
      option_parser.on("-h", "--help", "Show this message") do
        puts option_parser
        exit
      end

      # Create the version option
      option_parser.on("-v", "--version", "Show version") do
        puts "COSMOS Version: #{COSMOS_VERSION}"
        puts "User Version: #{USER_VERSION}" if defined? USER_VERSION
        exit
      end

      # Create the system option
      option_parser.on("--system FILE", "Use an alternative system.txt file") do |arg|
        System.instance(File.join(USERPATH, 'config', 'system', arg))
      end
    end
    parser.parse! if parse
    parser
  end

  # Get the ActiveRecord database handle to the decommutation table
  #
  # @param packet_config_id [Integer] PacketConfig table ID
  # @param table_index [Integer] Index into one of multiple decommutation tables.
  #   Since the number of columns is limited to MAX_COLUMNS_PER_TABLE there will
  #   be multiple tables for large packets.
  # @param reduction_modifier [String] Blank or one of '_m' for minutes, '_h' for hours,
  #   '_d' for days. These are the reduction tables.
  # @return [ActiveRecord::Base] The decommutation table model
  def get_decom_table_model(packet_config_id, table_index, reduction_modifier = "")
    model_name = "T#{packet_config_id}_#{table_index}#{reduction_modifier}"
    begin
      model = Cosmos.const_get(model_name)
    rescue
      # Need to create model
      model = Class.new(ActiveRecord::Base) do
        self.table_name = "t#{packet_config_id}_#{table_index}#{reduction_modifier}"
      end
      Cosmos.const_set(model_name, model)
    end
    return model
  end

  # Determine if the item must have separate raw and converted value tables
  #
  # @param item [Cosmos::PacketItem] Packet item
  # @return [Boolean] Whether the item must have separate raw and converted value tables
  def separate_raw_con?(item)
    # All items with states must have separate raw and converted values
    return true if item.states
    if item.data_type != :DERIVED
      # Non-derived items with a well defined read conversion have separate raw and converted
      return true if well_defined_read_conversion(item)
    end
    return false
  end

  # Create the packet configuration in the database. This includes the
  # ItemToDecomTableMapping which maps a telemetry item to its location in the
  # decommutation table as well as the actual decommutation tables which hold
  # the decommutated data. These tables are all named tXXX_YYY where XXX is the
  # PacketConfig ID and YYY is a table index when the packet has more than
  # MAX_COLUMNS_PER_TABLE and must span multiple tables. In addition the
  # reduction tables are setup with the '_m' (minute), '_h' (hour), '_d' (day)
  # extensions added to the tXXX_YYY tables (assuming the packets contain
  # data which can be reduced.)
  #
  # @param packet [Cosmos::Packet] Packet to create database tables for
  # @param packet_id [Integer] Id in the Packet table
  # @param packet_config [PacketConfig] ActiveRecord access to the PacketConfig table
  def setup_packet_config(packet, packet_id, packet_config)
    data_types = setup_item_to_decom_table_mapping(packet, packet_id, packet_config)
    table_index = 0
    # Grab MAX_COLUMNS_PER_TABLE of the total data_types and create a decommutation table
    # This will create a column for each data item named iX where X is a simple counter.
    # Thus the only way to know what data is in these tables is to use the
    # ItemToDecomTableMapping table.
    data_types.each_slice(MAX_COLUMNS_PER_TABLE) do |table_data_types|
      # Create overall decommutation table
      create_table("t#{packet_config.id}_#{table_index}") do |t|
        t.datetime :time
        t.bigint :ple_id
        t.bigint :meta_id
        t.integer :reduced_state, :default => 0
        table_data_types.each_with_index do |data_type, index|
          item_index = (table_index * MAX_COLUMNS_PER_TABLE) + index
          Cosmos::Logger::info("creating t#{packet_config.id}_#{table_index}:i#{item_index}")
          case data_type
          when :integer_array, :bigint_array, :float_array, :text_array, :binary_array, :decimal_array
            t.column "i#{item_index}", data_type.to_s.split("_")[0].intern, :array => true
          when :integer, :bigint, :float, :text, :binary, :decimal
            t.column "i#{item_index}", data_type
          when :string_array
            t.column "i#{item_index}", data_type.to_s.split("_")[0].intern, :array => true, :limit => MAX_STRING_BYTE_SIZE
          when :string
            t.column "i#{item_index}", data_type, :limit => MAX_STRING_BYTE_SIZE
          else
            raise "Unhandled db type: #{data_type}"
          end
        end
      end
      create_reduction_table("t#{packet_config.id}_#{table_index}_h", table_data_types, table_index) # hour
      create_reduction_table("t#{packet_config.id}_#{table_index}_m", table_data_types, table_index) # month
      create_reduction_table("t#{packet_config.id}_#{table_index}_d", table_data_types, table_index) # day
      table_index += 1
    end

    # Mark packet config ready
    packet_config.max_table_index = table_index - 1
    packet_config.ready = true
    packet_config.save
  end

  # Attempts to load a name system configuration. If the system configuration
  # can't be loaded locally, it is requested from the server and copied
  # locally before proceeding.
  #
  # @param system_config_name [String] System configuration name (MD5) to load
  def switch_and_get_system_config(system_config_name)
    # Switch to this new system configuration
    current_config, error = Cosmos::System.load_configuration(system_config_name)

    if current_config != system_config_name
      Cosmos::Logger.warn("Failed to load system_config: #{system_config_name}")
      Cosmos::Logger.warn("  Current config: #{current_config}")
      Cosmos::Logger.warn("  Error: #{error.formatted}") if error
      Cosmos::Logger.warn("  Will attempt to retrieve...")
      filename, data = get_saved_config(system_config_name)
      raise "No saved config" unless filename and data and data.length > 0
      configuration = File.join(Cosmos::System.paths['SAVED_CONFIG'], filename)
      unless File.exist?(configuration) and File.size(configuration) > 0
        File.open(configuration, 'wb') {|file| file.write(data)}
        File.chmod(0444, configuration) # Mark readonly
      end
      Cosmos::Logger.info("Configuration retrieved: #{configuration}")
      current_config, error = Cosmos::System.load_configuration(system_config_name)
      raise "Could not load config" if current_config != system_config_name
    end
  end

  # Iterate through all the defined commands and telemetry and create database
  # entries for all targets (Target table) and packets (Packet table).
  def sync_targets_and_packets
    sync_targets_packets(Cosmos::System.telemetry.all, is_tlm: true)
    sync_targets_packets(Cosmos::System.commands.all, is_tlm: false)
  end

  # Build the internal lookup tables to convert names to database ids
  def build_lookups
    # Get full target name and packet name lists from database
    targets = Target.all
    @target_name_to_id = {}
    @target_id_tlm_packet_name_to_id = {}
    @target_id_cmd_packet_name_to_id = {}
    @packet_id_item_name_to_id = {}
    targets.each do |target|
      @target_name_to_id[target.name] = target.id
      @target_id_tlm_packet_name_to_id[target.id] = {}
      @target_id_cmd_packet_name_to_id[target.id] = {}
      packets = Packet.where("target_id = #{target.id} and is_tlm = true").all
      packets.each do |packet|
        @target_id_tlm_packet_name_to_id[target.id][packet.name] = packet.id
        @packet_id_item_name_to_id[packet.id] = {}
        items = Item.where("packet_id = #{packet.id}").all
        items.each do |item|
          @packet_id_item_name_to_id[packet.id][item.name] = item.id
        end
      end
      packets = Packet.where("target_id = #{target.id} and is_tlm = false").all
      packets.each do |packet|
        @target_id_cmd_packet_name_to_id[target.id][packet.name] = packet.id
        @packet_id_item_name_to_id[packet.id] = {}
        items = Item.where("packet_id = #{packet.id}").all
        items.each do |item|
          @packet_id_item_name_to_id[packet.id][item.name] = item.id
        end
      end
    end
  end

  # Look up the database IDs of the given target and packet names
  #
  # @param target_name [String] Name of the target
  # @param packet_name [String] Name of the packet
  # @param is_tlm [Boolean] Whether the packet is telemetry (true) or commands (false)
  def lookup_target_and_packet_id(target_name, packet_name, is_tlm)
    target_id = @target_name_to_id[target_name] # Check cache
    unless target_id
      target = sync_target(target_name)
      target_id = target.id
      @target_name_to_id[target_name] = target_id # Update cache
      if is_tlm
        @target_id_tlm_packet_name_to_id[target_id] = {}
      else
        @target_id_cmd_packet_name_to_id[target_id] = {}
      end
    end
    if is_tlm
      packet_name_hash = @target_id_tlm_packet_name_to_id[target_id]
    else
      packet_name_hash = @target_id_cmd_packet_name_to_id[target_id]
    end
    packet_id = packet_name_hash[packet_name] # Check cache
    unless packet_id
      packet = sync_packet(target.id, packet_name, is_tlm)
      packet_id = packet.id
      packet_name_hash[packet_name] = packet.id  # Update cache
    end
    return [target_id, packet_id]
  end

  # Find the ActiveRecord database object for the given packet
  #
  # @param packet [Cosmos::Packet] COSMOS Packet to lookup
  # @param is_tlm [Boolean] Whether the packet is telemetry (true) or commands (false)
  # @return [ActiveRecord] PacketLogEntry ActiveRecord object
  def find_packet_log_entry(packet, is_tlm)
    target_id, packet_id = lookup_target_and_packet_id(packet.target_name, packet.packet_name, is_tlm)
    return PacketLogEntry.where("target_id = ? and packet_id = ? and is_tlm = ? and time = ?", target_id, packet_id, is_tlm, packet.received_time).first
  end

  # Read a Packet from the binary file by using the PacketLogEntry
  #
  # @param ple [ActiveRecord] PacketLogEntry ActiveRecord object
  # @return [Cosmos::Packet] Packet located by the PacketLookupTable
  def read_packet_from_ple(ple)
    begin
      @plr_cache ||= {}
      reader = @plr_cache[ple.packet_log_id]
      unless reader
        packet_log = PacketLog.find(ple.packet_log_id)
        reader = Cosmos::PacketLogReader.new
        reader.open(packet_log.filename)
        @plr_cache[packet_log.id] = reader
      end
      return reader.read_at_offset(ple.data_offset)
    rescue Exception => error
      Cosmos::Logger.error("Error Reading Packet Log Entry:\n#{error.formatted}")
      return nil
    end
  end

  protected

  # Look up the item id in the Item table based on the previously acquired packet id
  # Note: This method is only safe if lookup_target_and_packet_id was called
  # before it to get the packet_id
  #
  # @param packet_id [Integer] Database ID of the packet
  # @param item_name [String] Name of the item
  # @return [Integer] Database ID of the item
  def lookup_item_id(packet_id, item_name)
    @packet_id_item_name_to_id[packet_id] ||= {}
    item_name_hash = @packet_id_item_name_to_id[packet_id]
    item_id = item_name_hash[item_name] # Check cache
    unless item_id
      item = sync_item(packet_id, item_name)
      item_id = item.id
      item_name_hash[item_name] = item.id # Update cache
    end
    return item_id
  end

  # Convert the COSMOS data type, bit size, and array into a type used
  # by the SQL database.
  #
  # @param data_type [Symbol] One of :INT, :UINT, :FLOAT, :STRING, :BLOCK
  # @param bit_size [Integer] Size of the COSMOS data type
  # @param array_size [Integer, nil] Size of the array or nil if no array
  # @return [Symbol] Database type such as :integer, :bigint, :string, etc.
  def cosmos_data_type_to_db_type(data_type, bit_size, array_size)
    db_type = nil
    case data_type
    when :INT
      if bit_size <= 32
        db_type = :integer
      elsif bit_size <= 64
        db_type = :bigint
      else
        db_type = :decimal
      end
    when :UINT
      if bit_size <= 31
        db_type = :integer
      elsif bit_size <= 63
        db_type = :bigint
      else
        db_type = :decimal
      end
    when :FLOAT
      db_type = :float
    when :STRING
      if bit_size <= 0 or bit_size > MAX_STRING_BIT_SIZE
        db_type = :text
      else
        db_type = :string
      end
    when :BLOCK
      db_type = :binary
    else
      raise "Unsupported data type for db: #{data_type}:#{bit_size}"
    end
    db_type = (db_type.to_s + "_array").intern if array_size
    return db_type
  end

  # @param item [Cosmos::PacketItem] Item to convert to a SQL database type
  # @return [Array<Symbol, Symbol | nil>] SQL database type for the raw item
  #   followed by the converted item or nil if there is no conversion
  def get_db_types(item)
    raw_data_type = nil
    converted_data_type = nil
    if item.data_type == :DERIVED
      if item.read_conversion
        converted_data_type = cosmos_data_type_to_db_type(item.read_conversion.converted_type, item.read_conversion.converted_bit_size, item.read_conversion.converted_array_size)
        raw_data_type = converted_data_type
      end
      if item.states
        converted_data_type = cosmos_data_type_to_db_type(:STRING, MAX_STRING_BIT_SIZE, item.array_size)
      end
    else
      raw_data_type = cosmos_data_type_to_db_type(item.data_type, item.bit_size, item.array_size)
      if item.read_conversion
        converted_data_type = cosmos_data_type_to_db_type(item.read_conversion.converted_type, item.read_conversion.converted_bit_size, item.read_conversion.converted_array_size)
      elsif item.states
        converted_data_type = cosmos_data_type_to_db_type(:STRING, MAX_STRING_BIT_SIZE, item.array_size)
      end
    end
    return raw_data_type, converted_data_type
  end

  # Create the item to decommutation table mapping
  #
  # @param packet [Cosmos::Packet] Packet to create item mappings for
  # @param packet_id [Integer] Id in the Packet table
  # @param packet_config [PacketConfig] ActiveRecord access to the PacketConfig table
  # @return [Array<Symbol>] SQL database types for each item in the packet. Note there
  #   can be multiple values per item if an item has a raw and converted type.
  def setup_item_to_decom_table_mapping(packet, packet_id, packet_config)
    item_index = 0
    data_types = []

    # Cleanup old
    ItemToDecomTableMapping.where("packet_config_id = ?", packet_config.id).destroy_all

    packet.sorted_items.each do |item|
      # We don't handle DERIVED items without explicit types and sizes
      if item.data_type == :DERIVED
        next unless well_defined_read_conversion(item)
      end

      raw_data_type, converted_data_type = get_db_types(item)
      item_id = lookup_item_id(packet_id, item.name)
      if separate_raw_con?(item)
        # Need both RAW and CONVERTED
        ItemToDecomTableMapping.create(
          :item_id => item_id,
          :value_type => ItemToDecomTableMapping::RAW,
          :reduced => REDUCED_TYPES.include?(raw_data_type),
          :packet_config_id => packet_config.id,
          :table_index => item_index / MAX_COLUMNS_PER_TABLE,
          :item_index => item_index
        )
        item_index += 1
        data_types << raw_data_type
        ItemToDecomTableMapping.create(
          :item_id => item_id,
          :value_type => ItemToDecomTableMapping::CONVERTED,
          :reduced => REDUCED_TYPES.include?(converted_data_type),
          :packet_config_id => packet_config.id,
          :table_index => item_index / MAX_COLUMNS_PER_TABLE,
          :item_index => item_index
        )
        item_index += 1
        data_types << converted_data_type
      else
        # Can combine RAW and CONVERTED (RAW_CON)
        ItemToDecomTableMapping.create(
          :item_id => item_id,
          :value_type => ItemToDecomTableMapping::RAW_CON,
          :reduced => REDUCED_TYPES.include?(raw_data_type),
          :packet_config_id => packet_config.id,
          :table_index => item_index / MAX_COLUMNS_PER_TABLE,
          :item_index => item_index
        )
        item_index += 1
        data_types << raw_data_type
      end
    end

    return data_types
  end

  # Create a table in the database. Tables are first checked for existance
  # and dropped if they exist to ensure a clean table is created.
  def create_table(table_name)
    # Normally there would not be an existing decommutation table, however
    # in the off chance that DART crashed halfway through creating a packet
    # configuration we drop anything that may be existing.
    if ActiveRecord::Base.connection.table_exists?(table_name)
      ActiveRecord::Base.connection.drop_table(table_name)
    end
    ActiveRecord::Base.connection.create_table(table_name) do |table|
      yield table
    end
  end

  # Create a data reduction table. These tables hold min, max, and average
  # data points for values that can be reduced over longer time periods
  # for quicker access.
  def create_reduction_table(table_name, table_data_types, table_index)
    create_table(table_name) do |t|
      t.datetime :start_time
      t.integer :num_samples
      t.bigint :meta_id
      t.integer :reduced_state, :default => 0
      table_data_types.each_with_index do |data_type, index|
        item_index = (table_index * MAX_COLUMNS_PER_TABLE) + index
        case data_type
        when :integer, :bigint, :float, :decimal
          t.column "i#{item_index}max", data_type
          t.column "i#{item_index}min", data_type
          t.column "i#{item_index}avg", data_type
        end
      end
    end
  end

  def sync_target(target_name)
    target = Target.where("name = ?", target_name).first
    begin
      unless target
        target = Target.create(:name => target_name)
        Cosmos::Logger::info("Created Target:#{target.id}:#{target.name}")
      end
    rescue
      # Another thread probably already created it - Try to get it one more time
      target = Target.where("name = ?", target_name).first
    end
    target
  end

  def sync_packet(target_id, packet_name, is_tlm)
    packet = Packet.where("target_id = ? and name = ? and is_tlm = #{is_tlm}", target_id, packet_name).first
    begin
      unless packet
        packet = Packet.create(:target_id => target_id, :name => packet_name, :is_tlm => is_tlm)
        Cosmos::Logger::info("Created Packet:#{packet.id}:#{packet.target_id}:#{packet.name}:#{packet.is_tlm}")
      end
    rescue
      # Another thread probably already created it - Try to get it one more time
      packet = Packet.where("target_id = ? and name = ? and is_tlm = #{is_tlm}", target_id, packet_name).first
    end
    packet
  end

  def sync_item(packet_id, item_name)
    item = Item.where("packet_id = ? and name = ?", packet_id, item_name).first
    begin
      unless item
        item = Item.create(:packet_id => packet_id, :name => item_name)
        Cosmos::Logger::info("Created Item:#{item.id}:#{item.packet_id}:#{item.name}")
      end
    rescue
      # Another thread probably already created it - Try to get it one more time
      item = Item.where("packet_id = ? and name = ?", packet_id, item_name).first
    end
    item
  end

  def sync_targets_packets(tgt_pkt_hash, is_tlm:)
    tgt_pkt_hash.each do |target_name, packets|
      target = sync_target(target_name)
      packets.each do |packet_name, packet_obj|
        sync_packet(target.id, packet_name, is_tlm)
      end
    end
  end

  def well_defined_read_conversion(item)
    item.read_conversion && item.read_conversion.converted_type && item.read_conversion.converted_bit_size
  end
end