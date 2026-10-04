module Seaboar
  class Block
    attr_reader :cid, :data

    def initialize(cid, data)
      @cid = CID.parse(cid)
      @data = self.class.binary_string(data)
    end

    def self.dag_cbor(value)
      DagCbor.create_block(value)
    end

    def ==(other)
      other.is_a?(Block) && cid == other.cid && data == other.data
    end
    alias eql? ==

    def hash
      cid.hash ^ data.hash
    end

    def inspect
      "#<#{self.class} #{cid} (#{data.bytesize} bytes)>"
    end

    def self.binary_string(value)
      unless value.is_a?(String)
        raise InvalidBlockError.new('Block data must be a binary string')
      end
      value.dup.force_encoding(Encoding::ASCII_8BIT)
    end
  end

  class BlockSelection
    attr_reader :value, :blocks

    def initialize(value, blocks)
      @value = value
      @blocks = blocks
    end

    def to_ary
      [value, blocks]
    end
    alias to_a to_ary
  end
end
