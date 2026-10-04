require 'set'

module Seaboar
  module DagCbor
    TAG_CID = 42
    MAX_UINT64 = 0xffffffffffffffff
    MIN_INTEGER = -(2 ** 64)

    class Encoder < Seaboar::Encoder
      def initialize(input)
        super(input, :float_width => :half, :time_types => :string)
      end

      def encode_integer(number)
        if number < MIN_INTEGER || number > MAX_UINT64
          raise EncodingError.new('DAG-CBOR only supports 64-bit integers')
        end
        if number == MIN_INTEGER
          put_numeric_bytes(MAJ_TYPE_NEG_INT, MAX_UINT64)
        else
          super
        end
      end

      def encode_float(number)
        half = half_float_bits(number)
        if half
          put_type(MAJ_TYPE_FLOAT_OTHER, FLOAT_HALF)
          put_bytes([half].pack('n'))
        elsif [number].pack('g').unpack('g').first == number
          put_type(MAJ_TYPE_FLOAT_OTHER, FLOAT_SINGLE)
          put_bytes([number].pack('g'))
        else
          put_type(MAJ_TYPE_FLOAT_OTHER, FLOAT_DOUBLE)
          put_bytes([number].pack('G'))
        end
      end

      def encode_hash(hash)
        sorted = hash.sort_by do |key, _value|
          key_bytes = canonical_key_bytes(key)
          [key_bytes.bytesize, key_bytes]
        end
        put_numeric_bytes(MAJ_TYPE_MAP, sorted.size)
        sorted.each { |key, value| encode_object(key); encode_object(value) }
      end

      def encode_object(object)
        case object
        when CID
          unless object.version == 1
            raise EncodingError.new('DAG-CBOR links must use CIDv1')
          end
          put_numeric_bytes(MAJ_TYPE_TAG, TAG_CID)
          encode_string(object.link_bytes, MAJ_TYPE_BYTE_STR)
        when Integer
          encode_integer(object)
        when Float
          encode_float(object)
        when String
          encode_string(prepare_string(object), object.encoding == Encoding::ASCII_8BIT ? MAJ_TYPE_BYTE_STR : MAJ_TYPE_UTF8_STR)
        when Array
          encode_array(object)
        when Hash
          encode_hash(object)
        when true, false, nil
          super
        else
          raise EncodingError.new("DAG-CBOR cannot encode #{object.class}")
        end
      end

      def half_float_bits(number)
        return 0x7e00 if number.nan?
        return 0x7c00 if number == Float::INFINITY
        return 0xfc00 if number == -Float::INFINITY

        negative = number < 0 || (number.zero? && number.phase == Math::PI)
        sign = negative ? 0x8000 : 0
        sign_multiplier = negative ? -1 : 1
        absolute = number.abs
        if absolute < Math.ldexp(1, -25)
          return sign if absolute.zero?
          return nil
        end
        return nil if absolute > 65504.0

        exponent = Math.frexp(absolute).last - 1
        if exponent >= -14
          scaled = Math.ldexp(absolute, 10 - exponent)
          significand = round_even(scaled)
          return nil if significand < 1024 || significand > 2047
          candidate = sign | ((exponent + 15) << 10) | (significand & 0x3ff)
          rounded = Math.ldexp(significand, exponent - 10) * sign_multiplier
        else
          scaled = Math.ldexp(absolute, 24)
          mantissa = round_even(scaled)
          return nil if mantissa > 1023
          candidate = sign | mantissa
          rounded = Math.ldexp(mantissa, -24) * sign_multiplier
        end
        rounded == number ? candidate : nil
      end

      def round_even(number)
        floor = number.floor
        fraction = number - floor
        return floor if fraction < 0.5
        return floor + 1 if fraction > 0.5
        floor.even? ? floor : floor + 1
      end

      def canonical_key_bytes(key)
        unless key.is_a?(String) && key.encoding != Encoding::ASCII_8BIT
          raise EncodingError.new('DAG-CBOR map keys must be text strings')
        end
        begin
          key.encode(Encoding::UTF_8).force_encoding(Encoding::ASCII_8BIT)
        rescue ::EncodingError
          raise EncodingError.new('DAG-CBOR text must be valid UTF-8')
        end
      end

      private

      def prepare_string(string)
        return string.dup if string.encoding == Encoding::ASCII_8BIT

        begin
          bytes = string.encode(Encoding::UTF_8).force_encoding(Encoding::ASCII_8BIT)
        rescue ::EncodingError
          raise EncodingError.new('DAG-CBOR text must be valid UTF-8')
        end
        raise EncodingError.new('DAG-CBOR text must be valid UTF-8') unless valid_utf8_bytes?(bytes)
        bytes
      end

      def valid_utf8_bytes?(bytes)
        bytes.dup.force_encoding(Encoding::UTF_8).valid_encoding?
      end
    end

    class Decoder
      def initialize(input)
        @input = binary_input(input)
        @cursor = 0
      end

      def decode
        value = parse_one
        unless @cursor == @input.bytesize
          raise DecodingError.new('DAG-CBOR data contains trailing bytes')
        end
        value
      end

      private

      def binary_input(input)
        unless input.is_a?(String)
          raise DecodingError.new('DAG-CBOR input must be a binary string')
        end
        input.dup.force_encoding(Encoding::ASCII_8BIT)
      end

      def take(count)
        bytes = @input.byteslice(@cursor, count)
        if bytes.nil? || bytes.bytesize != count
          raise DecodingError.new('Unexpected end of DAG-CBOR data')
        end
        @cursor += count
        bytes
      end

      def parse_one
        byte = take(1).getbyte(0)
        major = (byte & 0xe0) >> 5
        extra = byte & 0x1f

        case major
        when MAJ_TYPE_UINT
          parse_uint(extra)
        when MAJ_TYPE_NEG_INT
          value = -1 - parse_uint(extra)
          if value < MIN_INTEGER
            raise DecodingError.new('DAG-CBOR integer is below the supported range')
          end
          value
        when MAJ_TYPE_BYTE_STR
          parse_byte_string(extra)
        when MAJ_TYPE_UTF8_STR
          parse_text(extra)
        when MAJ_TYPE_ARRAY
          parse_array(extra)
        when MAJ_TYPE_MAP
          parse_map(extra)
        when MAJ_TYPE_TAG
          parse_tag(extra)
        when MAJ_TYPE_FLOAT_OTHER
          parse_float_or_simple(extra)
        end
      end

      def parse_uint(extra)
        case extra
        when 0..UINT_MAX_INLINE
          extra
        when SUBTYPE_UINT8
          take(1).getbyte(0)
        when SUBTYPE_UINT16
          uint(take(2))
        when SUBTYPE_UINT32
          uint(take(4))
        when SUBTYPE_UINT64
          uint(take(8))
        when LENGTH_INDEFINITE
          raise DecodingError.new('DAG-CBOR does not permit indefinite-length values')
        else
          raise DecodingError.new('Reserved CBOR integer width')
        end
      end

      def uint(bytes)
        bytes.bytes.inject(0) { |value, byte| (value << 8) | byte }
      end

      def parse_byte_string(extra)
        if extra == LENGTH_INDEFINITE
          raise DecodingError.new('DAG-CBOR does not permit indefinite-length byte strings')
        end
        take(parse_uint(extra))
      end

      def parse_text(extra)
        bytes = parse_byte_string(extra)
        text = bytes.dup.force_encoding(Encoding::UTF_8)
        unless text.valid_encoding?
          raise DecodingError.new('DAG-CBOR text must be valid UTF-8')
        end
        text
      end

      def parse_array(extra)
        if extra == LENGTH_INDEFINITE
          raise DecodingError.new('DAG-CBOR does not permit indefinite-length arrays')
        end
        Array.new(parse_uint(extra)) { parse_one }
      end

      def parse_map(extra)
        if extra == LENGTH_INDEFINITE
          raise DecodingError.new('DAG-CBOR does not permit indefinite-length maps')
        end

        map = {}
        previous_key = nil
        parse_uint(extra).times do
          key = parse_one
          unless key.is_a?(String) && key.encoding == Encoding::UTF_8
            raise DecodingError.new('DAG-CBOR map keys must be text strings')
          end
          current_key = key_bytes(key)
          if previous_key && out_of_map_order?(current_key, previous_key)
            raise DecodingError.new('DAG-CBOR maps must be canonically sorted')
          end
          if map.key?(key)
            raise DecodingError.new('DAG-CBOR maps must not contain duplicate keys')
          end
          previous_key = current_key
          map[key] = parse_one
        end
        map
      end

      def key_bytes(key)
        key.encode(Encoding::UTF_8).force_encoding(Encoding::ASCII_8BIT)
      end

      def out_of_map_order?(current_key, previous_key)
        current_key.bytesize < previous_key.bytesize ||
          (current_key.bytesize == previous_key.bytesize && current_key <= previous_key)
      end

      def parse_tag(extra)
        tag = parse_uint(extra)
        unless tag == TAG_CID
          raise DecodingError.new("DAG-CBOR does not permit CBOR tag #{tag}")
        end

        link = parse_one
        unless link.is_a?(String) && link.encoding == Encoding::ASCII_8BIT && link.bytesize > 0 && link.getbyte(0) == 0
          raise DecodingError.new('CBOR tag 42 must wrap a zero-prefixed CID byte string')
        end

        cid = CID.from_bytes(link.byteslice(1, link.bytesize - 1))
        unless cid.version == 1
          raise DecodingError.new('DAG-CBOR links must use CIDv1')
        end
        cid
      rescue InvalidCIDError => error
        raise DecodingError.new(error.message)
      end

      def parse_float_or_simple(extra)
        case extra
        when SIMPLE_FALSE
          false
        when SIMPLE_TRUE
          true
        when SIMPLE_NULL
          nil
        when SIMPLE_UNDEF
          raise DecodingError.new('DAG-CBOR does not permit undefined')
        when SIMPLE_ONE_BYTE
          raise DecodingError.new('DAG-CBOR does not permit CBOR simple values')
        when FLOAT_HALF
          parse_half_float
        when FLOAT_SINGLE
          parse_float(4, 'g')
        when FLOAT_DOUBLE
          parse_float(8, 'G')
        when INDEFINITE_BREAK
          raise DecodingError.new('Unexpected CBOR break value')
        when 0..SIMPLE_MAXINLINE
          raise DecodingError.new('DAG-CBOR does not permit CBOR simple values')
        else
          raise DecodingError.new('Reserved CBOR float/simple width')
        end
      end

      def parse_float(width, directive)
        bytes = take(width)
        bytes.unpack(directive).first
      end

      def parse_half_float
        half = uint(take(2))
        exponent = (half >> 10) & 0x1f
        mantissa = half & 0x3ff
        sign = (half & 0x8000) == 0 ? 1 : -1

        value = case exponent
        when 0
          Math.ldexp(mantissa, -24)
        when 31
          mantissa.zero? ? Float::INFINITY : Float::NAN
        else
          Math.ldexp(mantissa + 1024, exponent - 25)
        end
        sign * value
      end
    end

    def self.encode(value)
      Encoder.new(value).encode
    end

    def self.decode(data)
      Decoder.new(data).decode
    end

    def self.create_block(value)
      data = encode(value)
      Block.new(CID.for_dag_cbor(data), data)
    end

    def self.select(value, path, block_store)
      BlockSelector.new(block_store).select(value, path)
    end

    def self.select_block(root, path, block_store)
      BlockSelector.new(block_store).select_block(root, path)
    end
  end
end
