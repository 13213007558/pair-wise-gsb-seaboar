module Seaboar
  class InMemoryBlockStore
    def initialize(blocks = [])
      @blocks = {}
      Array(blocks).each { |block| put(block) }
    end

    def put(block_or_cid, data = nil)
      block = coerce_block(block_or_cid, data)
      @blocks[block.cid.to_bytes] = block.data.dup
      block
    end
    alias add put

    def put_raw(cid, data)
      cid = CID.parse(cid)
      @blocks[cid.to_bytes] = Block.binary_string(data)
      cid
    end

    def get(cid)
      cid = CID.parse(cid)
      data = @blocks[cid.to_bytes]
      if data.nil?
        raise MissingBlockError.new("Missing block #{cid}")
      end

      CID.verify!(cid, data)
      Block.new(cid, data)
    end
    alias fetch get

    def key?(cid)
      @blocks.key?(CID.parse(cid).to_bytes)
    end
    alias has_key? key?
    alias include? key?

    def size
      @blocks.size
    end
    alias length size

    def to_a
      @blocks.map { |cid_bytes, data| Block.new(CID.from_bytes(cid_bytes), data) }
    end

    private

    def coerce_block(block_or_cid, data)
      if block_or_cid.is_a?(Block)
        unless data.nil?
          raise ArgumentError.new('Do not pass separate data when storing a Block')
        end
        Block.new(block_or_cid.cid, block_or_cid.data)
      else
        Block.new(block_or_cid, data)
      end
    end
  end
end
