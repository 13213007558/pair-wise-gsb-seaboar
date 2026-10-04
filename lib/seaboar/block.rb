module Seaboar
  class BlockError < StandardError; end
  class BlockIntegrityError < BlockError; end
  class InvalidBlockError < BlockError; end
  class MissingBlockError < BlockError; end
  class MissingLinkError < MissingBlockError; end
  class InvalidPathError < ArgumentError; end

  class Block
    attr_reader :cid, :data

    def self.create(value)
      new(DagCbor.encode(value))
    end

    def initialize(data, cid = nil)
      @data = data.to_s.dup.force_encoding('ASCII-8BIT').freeze
      @cid = cid ? normalize_cid(cid) : CID.for_dag_cbor(@data)
      verify!
      freeze
    end

    def ==(other)
      other.is_a?(Block) && cid == other.cid && data == other.data
    end
    alias eql? ==

    def hash
      [cid, data].hash
    end

    private

    def normalize_cid(cid)
      cid.is_a?(CID) ? cid : CID.from_bytes(cid)
    end

    def verify!
      cid.verify!(data)
    rescue CIDError
      raise BlockIntegrityError.new("block content does not match CID #{cid}")
    end
  end

  class MemoryBlockStore
    def initialize(blocks = [])
      @blocks = {}
      blocks.each { |block| put(block) }
    end

    def put(block_or_value)
      block = block_or_value.is_a?(Block) ? block_or_value : Block.create(block_or_value)
      @blocks[block.cid] = block
      block
    end

    def put_raw(cid, data)
      @blocks[normalize_cid(cid)] = data.to_s.dup.force_encoding('ASCII-8BIT')
      nil
    end

    def fetch(cid, &block)
      normalized = normalize_cid(cid)
      @blocks.fetch(normalized) do
        if block_given?
          block.call(normalized)
        else
          raise MissingBlockError.new("block not found: #{normalized}")
        end
      end
    end

    def [](cid)
      fetch(cid) { nil }
    end

    def key?(cid)
      @blocks.key?(normalize_cid(cid))
    end

    def size
      @blocks.size
    end

    private

    def normalize_cid(cid)
      cid.is_a?(CID) ? cid : CID.from_bytes(cid)
    end
  end

  Selection = Struct.new(:value, :blocks)

  class BlockService
    def initialize(block_store)
      @block_store = block_store
    end

    def select(root, path = [])
      path = path.is_a?(Array) ? path.dup : [path]
      used = {}
      root_block = root_block(root, used)
      value = decode_block(root_block)

      path.each do |segment|
        if value.is_a?(CID)
          linked_block = read_linked_block(value, used)
          value = decode_block(linked_block)
        end
        value = select_segment(value, segment)
      end

      Selection.new(value, used.values)
    end

    private

    def root_block(root, used)
      block = case root
      when Block
        validate_codec!(root.cid)
        root
      when CID
        validate_codec!(root)
        read_block(root)
      when String
        Block.new(root)
      else
        raise InvalidBlockError.new('root must be a CID, block, or encoded block string')
      end
      remember(block, used)
      block
    end

    def read_linked_block(cid, used)
      block = read_block(cid)
      remember(block, used)
      block
    rescue MissingBlockError
      raise MissingLinkError.new("linked block not found: #{cid}")
    end

    def read_block(cid)
      validate_codec!(cid)
      payload = fetch_payload(cid)
      data, block_cid = payload_data(payload)
      block = Block.new(data, block_cid || cid)
      raise BlockIntegrityError.new("returned block CID does not match requested CID #{cid}") unless block.cid == cid
      block
    end

    def validate_codec!(cid)
      unless cid.codec == CID::CODEC_DAG_CBOR
        raise InvalidBlockError.new("block #{cid} does not use the DAG-CBOR codec")
      end
    end

    def fetch_payload(cid)
      payload = @block_store.fetch(cid)
      raise MissingBlockError.new("block not found: #{cid}") if payload.nil?
      payload
    rescue KeyError
      raise MissingBlockError.new("block not found: #{cid}")
    end

    def payload_data(payload)
      case payload
      when Block
        [payload.data, payload.cid]
      when String
        [payload, nil]
      else
        if payload.respond_to?(:data) && payload.respond_to?(:cid)
          [payload.data, payload.cid]
        else
          raise InvalidBlockError.new('block store returned an unsupported payload')
        end
      end
    end

    def decode_block(block)
      DagCbor.decode(block.data)
    rescue ParseError, CIDError
      raise InvalidBlockError.new("block #{block.cid} is not valid DAG-CBOR")
    end

    def remember(block, used)
      used[block.cid] = block if block
    end

    def select_segment(value, segment)
      case value
      when Hash
        select_hash_segment(value, segment)
      when Array
        select_array_segment(value, segment)
      else
        raise InvalidPathError.new("cannot traverse #{value.class}")
      end
    end

    def select_hash_segment(hash, segment)
      key = case segment
      when String, Symbol
        segment.to_s
      when Integer
        segment
      else
        raise InvalidPathError.new('map path segments must be keys')
      end
      raise KeyError.new("key not found: #{segment.inspect}") unless hash.key?(key)
      hash[key]
    end

    def select_array_segment(array, segment)
      index = array_index(segment)
      raise IndexError.new("index #{index} is outside array bounds") unless index >= 0 && index < array.size
      array[index]
    end

    def array_index(segment)
      case segment
      when Integer
        segment
      when String
        raise InvalidPathError.new('array indexes must be non-negative integers') unless segment.match(/\A(?:0|[1-9]\d*)\z/)
        segment.to_i
      when Symbol
        array_index(segment.to_s)
      else
        raise InvalidPathError.new('array indexes must be non-negative integers')
      end.tap { |index| raise InvalidPathError.new('array indexes must be non-negative') if index < 0 }
    end
  end

  module DagCbor
    def self.block(value)
      Block.create(value)
    end

    def self.select(root, path, block_store)
      BlockService.new(block_store).select(root, path)
    end
  end
end
