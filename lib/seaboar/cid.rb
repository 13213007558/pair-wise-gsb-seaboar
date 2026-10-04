require 'digest/sha2'

module Seaboar
  class CID
    include Comparable
    SHA2_256 = 0x12
    IDENTITY = 0x00
    RAW = 0x55
    DAG_PB = 0x70
    DAG_CBOR = 0x71

    BASE58_ALPHABET = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz'
    BASE32_ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'

    attr_reader :version, :codec, :hash_algorithm, :digest, :multihash

    def self.for_dag_cbor(data)
      cidv1(DAG_CBOR, Digest::SHA256.digest(data), SHA2_256)
    end

    def self.cidv1(codec, digest, hash_algorithm = SHA2_256)
      new(1, codec, hash_algorithm, digest)
    end

    def self.from_bytes(bytes)
      bytes = binary_string(bytes)
      if v0_multihash?(bytes)
        new(0, DAG_PB, SHA2_256, bytes.byteslice(2, bytes.bytesize - 2), bytes)
      else
        if bytes.empty?
          raise InvalidCIDError.new('CID cannot be empty')
        end
        position = 0
        version = read_varint(bytes, position)
        unless [0, 1].include?(version)
          raise InvalidCIDError.new("Unsupported CID version #{version}")
        end
        position = varint_end(bytes, position)
        codec = read_varint(bytes, position)
        position = varint_end(bytes, position)
        multihash_start = position
        hash_algorithm = read_varint(bytes, position)
        position = varint_end(bytes, position)
        length = read_varint(bytes, position)
        position = varint_end(bytes, position)
        digest = bytes.byteslice(position, length)

        if digest.nil? || digest.bytesize != length || position + length != bytes.bytesize
          raise InvalidCIDError.new('CID multihash is truncated')
        end

        multihash = bytes.byteslice(multihash_start, bytes.bytesize - multihash_start)
        new(version, codec, hash_algorithm, digest, multihash)
      end
    end
    class << self
      alias parse_bytes from_bytes
    end

    def self.parse(value)
      case value
      when CID
        value
      when String
        unless value.encoding == Encoding::ASCII_8BIT
          value = value.dup.force_encoding(Encoding::ASCII_8BIT)
        end
        if value.start_with?('Qm') || value.start_with?('1')
          from_bytes(base58_decode(value))
        elsif value.start_with?('b', 'B')
          from_bytes(base32_decode(value[1, value.bytesize - 1]))
        else
          from_bytes(value)
        end
      else
        raise InvalidCIDError.new('CID must be a CID, string, or binary CID')
      end
    end

    def self.verify!(cid, data)
      cid = parse(cid)
      actual = digest_for(cid.hash_algorithm, data)
      unless actual.bytesize == cid.digest.bytesize && actual == cid.digest
        raise BlockIntegrityError.new("Block content does not match CID #{cid}")
      end
      true
    end

    def self.digest_matches?(cid, data)
      cid = parse(cid)
      actual = digest_for(cid.hash_algorithm, data)
      actual.bytesize == cid.digest.bytesize && actual == cid.digest
    end

    def initialize(version, codec, hash_algorithm, digest, multihash = nil)
      @version = version
      @codec = codec
      @hash_algorithm = hash_algorithm
      @digest = self.class.binary_string(digest)
      @multihash_input = multihash ? self.class.binary_string(multihash) : nil

      validate!
      @multihash = @multihash_input || build_multihash
      validate_multihash!
    end

    def to_bytes
      if version == 0
        multihash.dup
      else
        self.class.write_varint(version) <<
          self.class.write_varint(codec) <<
          multihash
      end
    end

    def link_bytes
      unless version == 1
        raise InvalidCIDError.new('DAG-CBOR links must use CIDv1')
      end
      "\x00".force_encoding(Encoding::ASCII_8BIT) << to_bytes
    end

    def to_s
      if version == 0
        self.class.base58_encode(multihash)
      else
        'b' << self.class.base32_encode(to_bytes).downcase
      end
    end

    def to_v1
      return self if version == 1
      self.class.new(1, DAG_PB, hash_algorithm, digest)
    end

    def ==(other)
      other.is_a?(CID) && to_bytes == other.to_bytes
    end
    alias eql? ==

    def hash
      to_bytes.hash
    end

    def <=>(other)
      return nil unless other.is_a?(CID)
      to_bytes <=> other.to_bytes
    end

    def inspect
      "#<#{self.class} #{self}>"
    end

    private

    def validate!
      unless [0, 1].include?(version)
        raise InvalidCIDError.new("Unsupported CID version #{version}")
      end
      unless codec.is_a?(Integer) && codec >= 0 && codec <= (2 ** 64 - 1)
        raise InvalidCIDError.new('CID codec must be an unsigned 64-bit integer')
      end
      unless hash_algorithm.is_a?(Integer) && hash_algorithm >= 0 && hash_algorithm <= (2 ** 64 - 1)
        raise InvalidCIDError.new('Multihash algorithm must be an unsigned 64-bit integer')
      end
      if digest.bytesize.zero?
        raise InvalidCIDError.new('CID digest cannot be empty')
      end
      if digest.bytesize > (2 ** 64 - 1)
        raise InvalidCIDError.new('CID digest is too large')
      end
      if version == 0 && (codec != DAG_PB || hash_algorithm != SHA2_256 || digest.bytesize != 32)
        raise InvalidCIDError.new('CIDv0 must use sha2-256 with dag-pb')
      end
    end

    def validate_multihash!
      if version == 0
        unless self.class.v0_multihash?(multihash)
          raise InvalidCIDError.new('Invalid CIDv0 multihash')
        end
      else
        rebuilt = self.class.write_varint(hash_algorithm) <<
          self.class.write_varint(digest.bytesize) << digest
        unless rebuilt == multihash
          raise InvalidCIDError.new('Invalid CID multihash')
        end
      end
    end

    def build_multihash
      self.class.write_varint(hash_algorithm) <<
        self.class.write_varint(digest.bytesize) << digest
    end

    class << self
      def binary_string(value)
        unless value.is_a?(String)
          raise InvalidCIDError.new('Expected binary data')
        end
        value.dup.force_encoding(Encoding::ASCII_8BIT)
      end

      def v0_multihash?(bytes)
        bytes.bytesize == 34 && bytes.getbyte(0) == SHA2_256 && bytes.getbyte(1) == 32
      end

      def write_varint(value)
        unless value.is_a?(Integer) && value >= 0 && value <= (2 ** 64 - 1)
          raise InvalidCIDError.new('Varint value must be an unsigned 64-bit integer')
        end
        bytes = ''.force_encoding(Encoding::ASCII_8BIT)
        loop do
          byte = value & 0x7f
          value >>= 7
          if value > 0
            bytes << (byte | 0x80).chr
          else
            bytes << byte.chr
            break
          end
        end
        bytes
      end

      def read_varint(bytes, start)
        value = 0
        shift = 0
        position = start
        loop do
          byte = bytes.getbyte(position)
          raise InvalidCIDError.new('Truncated varint') if byte.nil?
          value |= (byte & 0x7f) << shift
          position += 1
          if byte & 0x80 == 0
            return value
          end
          shift += 7
          if position - start >= 9
            raise InvalidCIDError.new('Varint is too large')
          end
        end
      end

      def varint_end(bytes, start)
        position = start
        loop do
          byte = bytes.getbyte(position)
          raise InvalidCIDError.new('Truncated varint') if byte.nil?
          position += 1
          return position if byte & 0x80 == 0
          raise InvalidCIDError.new('Varint is too large') if position - start >= 9
        end
      end

      def digest_for(algorithm, data)
        data = binary_string(data)
        case algorithm
        when SHA2_256
          Digest::SHA256.digest(data)
        when IDENTITY
          data
        else
          raise InvalidBlockError.new("Unsupported multihash algorithm 0x#{algorithm.to_s(16)}")
        end
      end

      def base58_encode(bytes)
        number = bytes.bytes.inject(0) { |value, byte| (value << 8) | byte }
        output = ''
        while number > 0
          number, remainder = number.divmod(58)
          output << BASE58_ALPHABET[remainder]
        end
        bytes.each_byte do |byte|
          break unless byte == 0
          output << BASE58_ALPHABET[0]
        end
        output.reverse
      end

      def base58_decode(string)
        number = 0
        string.each_char do |char|
          index = BASE58_ALPHABET.index(char)
          raise InvalidCIDError.new("Invalid Base58 character #{char}") if index.nil?
          number = number * 58 + index
        end

        bytes = ''.force_encoding(Encoding::ASCII_8BIT)
        while number > 0
          number, remainder = number.divmod(256)
          bytes << remainder.chr
        end
        string.each_char do |char|
          break unless char == BASE58_ALPHABET[0]
          bytes << 0.chr
        end
        bytes.reverse
      end

      def base32_encode(bytes)
        bits = bytes.bytes.map { |byte| format('%08b', byte) }.join
        output = bits.scan(/.{1,5}/).map do |chunk|
          BASE32_ALPHABET[chunk.ljust(5, '0').to_i(2)]
        end.join
        output
      end

      def base32_decode(string)
        normalized = string.upcase.delete('=')
        bits = normalized.each_char.map do |char|
          index = BASE32_ALPHABET.index(char)
          raise InvalidCIDError.new("Invalid Base32 character #{char}") if index.nil?
          format('%05b', index)
        end.join
        padding_bits = (normalized.bytesize * 5) % 8
        if padding_bits.zero? && bits.bytesize % 8 != 0
          raise InvalidCIDError.new('Invalid Base32 CID length')
        end
        unless padding_bits.zero? || bits[-(padding_bits), padding_bits] == '0' * padding_bits
          raise InvalidCIDError.new('Invalid Base32 CID padding bits')
        end
        bytes = bits.scan(/.{8}/).map { |chunk| chunk.to_i(2).chr }.join
        bytes.force_encoding(Encoding::ASCII_8BIT)
      end
    end
  end
end
