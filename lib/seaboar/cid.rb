require 'digest'

module Seaboar
  class CIDError < StandardError; end
  class InvalidCIDError < CIDError; end
  class DigestMismatchError < CIDError; end
  class UnsupportedDigestError < CIDError; end

  class CID
    CODEC_DAG_CBOR = 0x71
    CODEC_DAG_PB = 0x70
    HASH_SHA2_256 = 0x12

    BASE32_ALPHABET = "abcdefghijklmnopqrstuvwxyz234567".freeze
    BASE58_ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz".freeze

    attr_reader :version, :codec, :multihash_code, :digest_length, :digest, :raw_bytes

    def self.for_dag_cbor(data)
      multihash = [HASH_SHA2_256, 0x20].pack('C*') + Digest::SHA256.digest(data)
      from_components(1, CODEC_DAG_CBOR, multihash)
    end

    def self.from_bytes(bytes)
      bytes = bytes.to_s.dup.force_encoding('ASCII-8BIT')

      if bytes.bytesize == 34 && bytes.getbyte(0) == HASH_SHA2_256
        digest, multihash_code, digest_length = parse_multihash!(bytes, 0, 32)
        return new(0, CODEC_DAG_PB, bytes, multihash_code, digest_length, digest)
      end

      version, position = read_varint(bytes, 0)
      raise InvalidCIDError.new('unsupported CID version') unless version == 1

      codec, multihash_start = read_varint(bytes, position)
      digest, multihash_code, digest_length = parse_multihash!(bytes, multihash_start)

      new(version, codec, bytes, multihash_code, digest_length, digest)
    end

    def self.from_components(version, codec, multihash)
      multihash_code, position = read_varint(multihash, 0)
      digest_length, position = read_varint(multihash, position)
      digest, multihash_code, digest_length = parse_multihash!(multihash, 0)
      raw = encode_varint(version) + encode_varint(codec) + multihash
      new(version, codec, raw, multihash_code, digest_length, digest)
    end

    def self.read_varint(bytes, position)
      value = 0
      shift = 0

      loop do
        raise InvalidCIDError.new('truncated varint') if position >= bytes.bytesize
        byte = bytes.getbyte(position)
        position += 1
        value |= (byte & 0x7f) << shift
        break unless (byte & 0x80) == 0x80
        shift += 7
        raise InvalidCIDError.new('varint is too large') if shift > 63
      end

      [value, position]
    end

    def self.encode_varint(value)
      result = ''.force_encoding('ASCII-8BIT')
      loop do
        byte = value & 0x7f
        value >>= 7
        if value == 0
          result << byte.chr
          break
        else
          result << (byte | 0x80).chr
        end
      end
      result
    end

    def self.parse_multihash!(bytes, position, expected_length = nil)
      multihash_code, after_codec = read_varint(bytes, position)
      digest_length, position = read_varint(bytes, after_codec)
      raise InvalidCIDError.new('invalid multihash length') if expected_length && digest_length != expected_length
      digest = bytes.byteslice(position, digest_length)
      raise InvalidCIDError.new('truncated multihash digest') if digest.nil? || digest.bytesize != digest_length
      raise InvalidCIDError.new('trailing multihash bytes') unless position + digest_length == bytes.bytesize
      [digest, multihash_code, digest_length]
    end

    private_class_method :new

    def initialize(version, codec, raw_bytes, multihash_code, digest_length, digest)
      @version = version
      @codec = codec
      @raw_bytes = raw_bytes.dup.freeze
      @multihash_code = multihash_code
      @digest_length = digest_length
      @digest = digest.dup.freeze
    end

    def link_bytes
      if version == 1
        raw_bytes
      else
        "\x01".b + self.class.encode_varint(codec) + multihash_bytes
      end
    end

    def multihash_bytes
      self.class.encode_varint(multihash_code) + self.class.encode_varint(digest_length) + digest
    end

    def verify!(data)
      if multihash_code == HASH_SHA2_256 && digest_length == 32
        actual = Digest::SHA256.digest(data)
        unless actual == digest
          raise DigestMismatchError.new("block digest does not match CID #{self}")
        end
      else
        raise UnsupportedDigestError.new("unsupported multihash code #{multihash_code}")
      end
    end

    def ==(other)
      other.is_a?(CID) && raw_bytes == other.raw_bytes
    end
    alias eql? ==

    def hash
      raw_bytes.hash
    end

    def to_s
      version == 1 ? "b#{base32(raw_bytes)}" : base58(raw_bytes)
    end

    def inspect
      "#<Seaboar::CID #{self}>"
    end

    private

    def base32(bytes)
      bits = bytes.bytes.map { |byte| format('%08b', byte) }.join
      output = bits.scan(/.{1,5}/).map do |chunk|
        chunk << '0' while chunk.bytesize < 5
        BASE32_ALPHABET[chunk.to_i(2)]
      end.join
      output.sub(/=+\z/, '')
    end

    def base58(bytes)
      number = bytes.bytes.inject(0) { |value, byte| value * 256 + byte }
      output = ''.force_encoding('ASCII-8BIT')
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
  end

  Link = CID
end
