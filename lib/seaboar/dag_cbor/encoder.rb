module Seaboar
  module DagCbor
    class Encoder < Seaboar::Encoder
      def initialize(input)
        super(input, :float_width => :double, :time_types => :string)
      end

      def encode_float(number)
        put_type(MAJ_TYPE_FLOAT_OTHER, FLOAT_DOUBLE)
        put_bytes([number].pack('G'))
      end

      def encode_object(object)
        case object
        when CID
          put_numeric_bytes(MAJ_TYPE_TAG, TAG_CID)
          encode_string("\x00".b + object.link_bytes, MAJ_TYPE_BYTE_STR)
        when Integer
          unless object >= MIN_INT && object <= MAX_INT
            raise EncodingError.new('DAG-CBOR integers must fit in a signed 64-bit value')
          end
          super
        when Symbol
          raise EncodingError.new('DAG-CBOR does not support symbols')
        when String
          if object.encoding == Encoding::ASCII_8BIT
            super
          elsif object.valid_encoding?
            super(object.encode(Encoding::UTF_8))
          else
            raise EncodingError.new('strings must be valid UTF-8 text')
          end
        when Hash
          encode_dag_map(object)
        when Array, Float
          super
        else
          if object == true || object == false || object.nil?
            super
          else
            raise EncodingError.new("DAG-CBOR does not support #{object.class}")
          end
        end
      end

      def encode_dag_map(hash)
        entries = hash.map do |key, value|
          unless key.is_a?(String) && key.encoding != Encoding::ASCII_8BIT && key.valid_encoding?
            raise EncodingError.new('DAG-CBOR map keys must be UTF-8 strings')
          end
          [key, value, key.encode(Encoding::UTF_8).b]
        end

        groups = entries.group_by { |_key, _value, key_bytes| key_bytes }
        raise EncodingError.new('DAG-CBOR maps cannot contain duplicate keys') if groups.any? { |_key_bytes, group| group.size > 1 }

        entries.sort! do |left, right|
          by_length = left[2].bytesize <=> right[2].bytesize
          by_length == 0 ? left[2] <=> right[2] : by_length
        end

        put_numeric_bytes(MAJ_TYPE_MAP, entries.size)
        entries.each { |key, value, _| encode_object(key); encode_object(value) }
      end
    end
  end
end
