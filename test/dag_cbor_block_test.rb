require_relative('test_helper')

require 'digest'

class DagCborBlockTests < MiniTest::Test
  def setup
    @leaf = Seaboar::Block.create('n' => 1)
    @shared = Seaboar::Block.create(
      'item' => @leaf.cid,
      'text' => 'shared'
    )
    @tampered_original = Seaboar::Block.create('x' => 1)
    @missing_cid = Seaboar::Block.create('missing' => true).cid
    @root = Seaboar::Block.create(
      'b' => false,
      'a' => 1,
      'list' => [@leaf.cid],
      'shared' => @shared.cid,
      'again' => @shared.cid,
      'tampered' => @tampered_original.cid,
      'missing' => @missing_cid
    )
    @store = Seaboar::MemoryBlockStore.new([@leaf, @shared, @root])
    @store.put_raw(@tampered_original.cid, @tampered_original.data + '\x00'.b)
  end

  def test_generates_cidv1_dag_cbor_sha256
    assert_equal(1, @leaf.cid.version)
    assert_equal(Seaboar::CID::CODEC_DAG_CBOR, @leaf.cid.codec)
    assert_equal(Seaboar::CID::HASH_SHA2_256, @leaf.cid.multihash_code)
    assert_equal(32, @leaf.cid.digest_length)
    assert_equal(Digest::SHA256.digest(@leaf.data), @leaf.cid.digest)
    assert @leaf.cid.to_s.start_with?('bafyrei')
  end

  def test_cid_round_trips_from_raw_bytes
    cid = Seaboar::CID.from_bytes(@leaf.cid.raw_bytes)
    assert_equal(@leaf.cid, cid)
    assert_equal(@leaf.cid.raw_bytes, cid.raw_bytes)
  end

  def test_encodes_canonical_dag_cbor
    encoded = Seaboar::DagCbor.encode(
      'by' => true,
      'a' => 1,
      'b' => false
    )
    assert_equal(hex_string_to_byte_string('a36161016162f4626279f5'), encoded)
  end

  def test_encodes_float_as_double_precision
    encoded = Seaboar::DagCbor.encode(1.5)
    assert_equal(hex_string_to_byte_string('fb3ff8000000000000'), encoded)
  end

  def test_encodes_link_with_tag_42
    encoded = Seaboar::DagCbor.encode('link' => @leaf.cid)
    prefix = hex_string_to_byte_string('a1646c696e6bd82a582500')
    assert_equal(prefix, encoded.byteslice(0, prefix.bytesize))

    decoded = Seaboar::DagCbor.decode(encoded)
    assert_equal(@leaf.cid, decoded['link'])
  end

  def test_rejects_values_outside_dag_cbor
    assert_raises(Seaboar::DagCbor::EncodingError) do
      Seaboar::DagCbor.encode(:bad)
    end
    assert_raises(Seaboar::DagCbor::EncodingError) do
      Seaboar::DagCbor.encode(1 => 'bad')
    end
    assert_raises(Seaboar::DagCbor::EncodingError) do
      Seaboar::DagCbor.encode(Time.now)
    end
    assert_raises(Seaboar::DagCbor::EncodingError) do
      Seaboar::DagCbor.encode(2 ** 63)
    end
  end

  def test_decoder_rejects_non_canonical_dag_cbor
    wrong_order = hex_string_to_byte_string('a2616202616101')
    assert_raises(Seaboar::DagCbor::InvalidMapError) do
      Seaboar::DagCbor.decode(wrong_order)
    end

    undefined = hex_string_to_byte_string('f7')
    assert_raises(Seaboar::DagCbor::DecodingError) do
      Seaboar::DagCbor.decode(undefined)
    end
  end

  def test_root_selection_returns_root_block_only
    result = select([])
    expected = {
      'a' => 1,
      'b' => false,
      'list' => [@leaf.cid],
      'shared' => @shared.cid,
      'again' => @shared.cid,
      'tampered' => @tampered_original.cid,
      'missing' => @missing_cid
    }
    assert_equal(expected, result.value)
    assert_equal([@root.cid], cids(result))
  end

  def test_tampered_link_is_detected_by_digest
    assert_raises(Seaboar::BlockIntegrityError) do
      select(['tampered', 'x'])
    end
  end

  def test_path_dereferences_shared_links_and_deduplicates_blocks
    result = select(['shared', 'item', 'n'])
    assert_equal(1, result.value)
    assert_equal([@root.cid, @shared.cid, @leaf.cid], cids(result))
  end

  def test_array_index_path_uses_only_selected_blocks
    result = select(['list', 0, 'n'])
    assert_equal(1, result.value)
    assert_equal([@root.cid, @leaf.cid], cids(result))
  end

  def test_numeric_string_is_accepted_as_array_index
    result = select(['list', '0', 'n'])
    assert_equal(1, result.value)
    assert_equal([@root.cid, @leaf.cid], cids(result))
  end

  def test_link_at_path_end_is_not_dereferenced
    result = select(['shared', 'item'])
    assert_equal(@leaf.cid, result.value)
    assert_equal([@root.cid, @shared.cid], cids(result))
  end

  def test_missing_link_is_distinct_from_missing_key
    error = assert_raises(Seaboar::MissingLinkError) do
      select(['missing', 'n'])
    end
    assert_kind_of(Seaboar::MissingBlockError, error)
    assert_includes(error.message, @missing_cid.to_s)
  end

  def test_missing_key_is_not_reported_as_missing_link
    assert_raises(KeyError) do
      select(['shared', 'item', 'missing'])
    end
  end

  def test_array_index_out_of_bounds_is_specific
    assert_raises(IndexError) do
      select(['list', 2, 'n'])
    end
  end

  def test_missing_root_is_reported_as_missing_block
    service = Seaboar::BlockService.new(Seaboar::MemoryBlockStore.new)
    assert_raises(Seaboar::MissingBlockError) do
      service.select(@root.cid)
    end
  end

  def test_every_read_checks_content_digest
    other = Seaboar::Block.create('different' => true)
    assert_raises(Seaboar::BlockIntegrityError) do
      Seaboar::Block.new(@leaf.data, other.cid)
    end

    @store.put_raw(@leaf.cid, @leaf.data + '\x00'.b)
    assert_raises(Seaboar::BlockIntegrityError) do
      select(['list', 0, 'n'])
    end
  end

  def test_accepts_an_injectable_duck_typed_block_store
    blocks = {
      @root.cid => @root.data,
      @shared.cid => @shared.data,
      @leaf.cid => @leaf.data
    }
    service = Seaboar::BlockService.new(blocks)
    result = service.select(@root.cid, ['shared', 'item', 'n'])
    assert_equal(1, result.value)
  end

  private

  def select(path)
    Seaboar::BlockService.new(@store).select(@root.cid, path)
  end

  def cids(result)
    result.blocks.map(&:cid)
  end
end
