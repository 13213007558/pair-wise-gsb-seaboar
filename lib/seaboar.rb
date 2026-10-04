require "seaboar/version"
require "seaboar/constants"
require "seaboar/errors"
require "seaboar/decoder"
require "seaboar/encoder"
require "seaboar/cid"
require "seaboar/block"
require "seaboar/dag_cbor"
require "seaboar/block_store"
require "seaboar/block_selector"

module Seaboar
  def self.decode(input)
    Seaboar::Decoder.new(input).decode
  end

  def self.encode(input, options={})
    Seaboar::Encoder.new(input, options).encode
  end

  def self.encode_dag_cbor(value)
    DagCbor.encode(value)
  end

  def self.decode_dag_cbor(data)
    DagCbor.decode(data)
  end

  def self.create_dag_cbor_block(value)
    DagCbor.create_block(value)
  end

  def self.select_dag_cbor(root, path, block_store)
    DagCbor.select(root, path, block_store)
  end
end

Seaboar::DAGCBOR = Seaboar::DagCbor
