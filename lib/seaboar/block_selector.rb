require 'set'

module Seaboar
  class BlockSelector
    def initialize(block_store)
      unless block_store.respond_to?(:get)
        raise ArgumentError.new('block_store must respond to #get')
      end
      @block_store = block_store
      @blocks = Set.new
      @loaded_nodes = {}
    end

    def select(value, path = [])
      current = load_root(value)
      segments = normalize_path(path)
      current = load_link_node(current) if current.is_a?(CID)
      segments.each do |segment|
        current = select_segment(current, segment)
        current = load_link_node(current) if current.is_a?(CID)
      end
      BlockSelection.new(current, @blocks.dup)
    end

    def select_block(block, path = [])
      select(block, path)
    end

    private

    def load_root(value)
      case value
      when CID
        load_link_node(value)
      when Block
        load_supplied_block(value)
      when String
        DagCbor.decode(value)
      else
        value
      end
    end

    def load_supplied_block(block)
      CID.verify!(block.cid, block.data)
      remember_block(block)
      decode_remembered_block(block)
    end

    def select_segment(node, segment)
      case segment
      when String
        if node.is_a?(Hash)
          unless node.key?(segment)
            raise PathNotFoundError.new("Map key #{segment.inspect} does not exist")
          end
          node[segment]
        elsif node.is_a?(Array) && array_index?(segment)
          index = Integer(segment, 10)
          unless index >= 0 && index < node.size
            raise PathNotFoundError.new("Array index #{index} does not exist")
          end
          node[index]
        else
          raise PathResolutionError.new("Path segment #{segment.inspect} cannot be selected from #{node.class}")
        end
      when Integer
        unless node.is_a?(Array)
          raise PathResolutionError.new("Index #{segment} cannot be selected from #{node.class}")
        end
        unless segment >= 0 && segment < node.size
          raise PathNotFoundError.new("Array index #{segment} does not exist")
        end
        node[segment]
      else
        raise InvalidPathError.new('Path segments must be strings or integers')
      end
    end

    def array_index?(segment)
      return false if segment.start_with?('+') || segment.start_with?('-')
      begin
        Integer(segment, 10)
        true
      rescue ArgumentError
        false
      end
    end

    def normalize_path(path)
      case path
      when Array
        path
      when String
        path.split('/')
      else
        raise InvalidPathError.new('Path must be an array of keys and indexes or a string path')
      end.each do |segment|
        unless segment.is_a?(String) || segment.is_a?(Integer)
          raise InvalidPathError.new('Path segments must be strings or integers')
        end
        if segment.is_a?(Integer) && segment < 0
          raise InvalidPathError.new('Array indexes cannot be negative')
        end
      end
    end

    def load_link_node(cid)
      key = cid.to_bytes
      return @loaded_nodes[key] if @loaded_nodes.key?(key)

      block = fetch_block(cid)
      remember_block(block)
      node = decode_remembered_block(block)
      @loaded_nodes[key] = node
    end

    def fetch_block(cid)
      result = @block_store.get(cid)
      block = case result
      when Block
        result
      when String
        Block.new(cid, result)
      else
        raise MissingLinkError.new("block_store#get must return a Block or binary string for #{cid}")
      end

      unless block.cid == cid
        raise InvalidBlockError.new("block_store returned CID #{block.cid} for request #{cid}")
      end
      CID.verify!(block.cid, block.data)
      block
    rescue MissingBlockError => error
      raise MissingLinkError.new(error.message)
    end

    def remember_block(block)
      @blocks.add(block)
    end

    def decode_remembered_block(block)
      case block.cid.codec
      when CID::DAG_CBOR
        DagCbor.decode(block.data)
      when CID::RAW
        block.data
      else
        raise InvalidBlockError.new("Cannot decode codec 0x#{block.cid.codec.to_s(16)} block #{block.cid}")
      end
    end
  end
end
