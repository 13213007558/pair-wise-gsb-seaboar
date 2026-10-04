module Seaboar
  module DagCbor
    class Decoder < Seaboar::Decoder
      def initialize(input)
        super
        @pending_cid = false
      end

      def push_tag(extra)
        raise InvalidTagError.new('nested CBOR tags are not allowed') unless @tag.nil? && !@pending_cid
        tag = take_uint(extra)
        raise InvalidTagError.new("CBOR tag #{tag} is not allowed in DAG-CBOR") unless tag == TAG_CID
        @tag = nil
        @pending_cid = true
      end

      def parse_byte_string(extra)
        raise IndefiniteLengthError.new('indefinite-length byte strings are not allowed') if extra == LENGTH_INDEFINITE
        was_pending_cid = @pending_cid
        @pending_cid = false
        @tag = TAG_CID if was_pending_cid
        super
      end

      def interpret_byte_string(value)
        if @tag == TAG_CID
          raise InvalidLinkEncodingError.new('tagged CID bytes must be prefixed with 0x00') unless value.getbyte(0) == 0
          cid = CID.from_bytes(value.byteslice(1, value.bytesize - 1))
          raise InvalidLinkEncodingError.new('CID links in DAG-CBOR must use CIDv1') unless cid.version == 1
          @tag = nil
          cid
        else
          value
        end
      rescue CIDError => error
        raise InvalidLinkEncodingError.new(error.message)
      end

      def assert_not_pending_cid
        raise InvalidTagError.new('CBOR tag 42 may only precede a byte string') if @pending_cid
      end

      def parse_uint(extra)
        assert_not_pending_cid
        value = super
        raise DecodingError.new('DAG-CBOR integers must fit in a signed 64-bit value') if value > MAX_INT
        value
      end

      def parse_neg_int(extra)
        assert_not_pending_cid
        value = super
        raise DecodingError.new('DAG-CBOR integers must fit in a signed 64-bit value') if value < MIN_INT
        value
      end

      def parse_utf8_string(extra)
        raise IndefiniteLengthError.new('indefinite-length strings are not allowed') if extra == LENGTH_INDEFINITE
        assert_not_pending_cid
        super
      end

      def parse_float_or_simple(extra)
        assert_not_pending_cid
        if extra == FLOAT_HALF || extra == FLOAT_SINGLE
          raise DecodingError.new('DAG-CBOR floats must use 64-bit IEEE 754 encoding')
        end
        if extra == SIMPLE_ONE_BYTE || !(SIMPLE_FALSE..SIMPLE_NULL).include?(extra)
          raise DecodingError.new("CBOR simple value #{extra} is not allowed in DAG-CBOR")
        end
        super
      end

      def interpret_utf8_string(raw_str)
        raise DecodingError.new('text strings must be valid UTF-8') unless raw_str.valid_encoding?
        super
      end

      def parse_array(extra)
        raise IndefiniteLengthError.new('indefinite-length arrays are not allowed') if extra == LENGTH_INDEFINITE
        assert_not_pending_cid
        length = parse_uint(extra)
        Array.new(length) { parse_value }
      end

      def parse_map(extra)
        raise IndefiniteLengthError.new('indefinite-length maps are not allowed') if extra == LENGTH_INDEFINITE
        assert_not_pending_cid
        length = parse_uint(extra)
        map = {}
        previous_key = nil

        length.times do
          key = parse_value
          value = parse_value
          unless key.is_a?(String) && key.encoding != Encoding::ASCII_8BIT
            raise InvalidMapError.new('DAG-CBOR map keys must be UTF-8 strings')
          end

          key_bytes = key.b
          if previous_key
            by_length = previous_key.bytesize <=> key_bytes.bytesize
            ordered = by_length < 0 || (by_length == 0 && (previous_key <=> key_bytes) < 0)
            raise InvalidMapError.new('map keys are not in canonical DAG-CBOR order') unless ordered
          end
          raise InvalidMapError.new('duplicate map key') if map.key?(key)

          map[key] = value
          previous_key = key_bytes
        end

        map
      end

      def decode
        parse_value

        raise DecodingError.new('DAG-CBOR blocks must contain exactly one value') unless @cursor == @input.bytesize
        @value
      end

      private

      def parse_value
        parse_one
        if @pending_cid
          raise InvalidTagError.new('truncated tagged value') if @cursor >= @input.bytesize
          parse_one
        end
        @value
      end
    end
  end
end
