module Seaboar
  module DagCbor
    TAG_CID = 42
    MAX_INT = 2 ** 63 - 1
    MIN_INT = -2 ** 63

    class EncodingError < StandardError; end
    class DecodingError < ParseError; end
    class InvalidLinkEncodingError < DecodingError; end
    class InvalidTagError < DecodingError; end
    class InvalidMapError < DecodingError; end
    class IndefiniteLengthError < DecodingError; end

    require 'seaboar/dag_cbor/encoder'
    require 'seaboar/dag_cbor/decoder'

    def self.encode(value)
      Encoder.new(value).encode
    end

    def self.decode(bytes)
      Decoder.new(bytes).decode
    end
  end
end
