require_relative('test_helper')

class DagCborTests < MiniTest::Test
  def test_encodes_canonical_maps_by_length_then_bytes
    actual = Seaboar.encode_dag_cbor({ 'z' => 1, 'aa' => 2 })
    assert_equal('a2617a0162616102', hex(actual))
  end

  def test_rejects_non_text_map_keys
    error = assert_raises(Seaboar::EncodingError) do
      Seaboar.encode_dag_cbor({ 1 => 2 })
    end
    assert_match(/map keys/, error.message)
  end

  def test_rejects_types_outside_the_ipld_data_model
    error = assert_raises(Seaboar::EncodingError) do
      Seaboar.encode_dag_cbor(:symbol)
    end
    assert_match(/cannot encode Symbol/, error.message)
  end

  def test_uses_shortest_canonical_float_width
    assert_equal('f93e00', hex(Seaboar.encode_dag_cbor(1.5)))
    assert_equal('fb3ff199999999999a', hex(Seaboar.encode_dag_cbor(1.1)))
  end

  def test_supports_full_64_bit_integer_range
    [-2 ** 64, -2 ** 63, 0, 2 ** 64 - 1].each do |number|
      encoded = Seaboar.encode_dag_cbor(number)
      assert_equal(number, Seaboar.decode_dag_cbor(encoded))
    end
  end

  def test_rejects_out_of_range_integers
    assert_raises(Seaboar::EncodingError) do
      Seaboar.encode_dag_cbor(2 ** 64)
    end
    assert_raises(Seaboar::EncodingError) do
      Seaboar.encode_dag_cbor(-(2 ** 64) - 1)
    end
  end

  def test_round_trips_a_cid_link
    cid = Seaboar.create_dag_cbor_block({ 'ok' => true }).cid
    encoded = Seaboar.encode_dag_cbor({ 'link' => cid })
    decoded = Seaboar.decode_dag_cbor(encoded)

    assert_equal(cid, decoded['link'])
    assert_includes(hex(encoded), 'd82a5825')
  end

  def test_decoder_rejects_non_canonical_maps
    encoded = bytes('a262616102617a01')
    error = assert_raises(Seaboar::DecodingError) do
      Seaboar.decode_dag_cbor(encoded)
    end
    assert_match(/canonically sorted/, error.message)
  end

  def test_decoder_rejects_indefinite_values_and_other_tags
    assert_raises(Seaboar::DecodingError) do
      Seaboar.decode_dag_cbor(bytes('9f01ff'))
    end
    assert_raises(Seaboar::DecodingError) do
      Seaboar.decode_dag_cbor(bytes('c060'))
    end
  end

  def test_decoder_rejects_undefined_and_trailing_data
    assert_raises(Seaboar::DecodingError) do
      Seaboar.decode_dag_cbor(bytes('f7'))
    end
    assert_raises(Seaboar::DecodingError) do
      Seaboar.decode_dag_cbor(bytes('0102'))
    end
  end

  def test_cid_round_trips_through_canonical_base32
    cid = Seaboar.create_dag_cbor_block({ 'a' => 1 }).cid
    assert_equal(cid, Seaboar::CID.parse(cid.to_s))
    assert_equal(cid, Seaboar::CID.parse(cid.to_bytes))
    assert_operator(cid.to_s, :start_with?, 'bafyrei')
  end

  def test_selects_a_path_across_links_with_shared_used_blocks
    shared = Seaboar.create_dag_cbor_block({ 'name' => 'shared' })
    left = Seaboar.create_dag_cbor_block({ 'child' => shared.cid, 'n' => 1 })
    right = Seaboar.create_dag_cbor_block({ 'child' => shared.cid, 'n' => 2 })
    root = Seaboar.create_dag_cbor_block({
      'left' => left.cid,
      'right' => right.cid,
      'shared' => shared.cid
    })
    store = Seaboar::InMemoryBlockStore.new([root, left, right, shared])

    result, blocks = Seaboar.select_dag_cbor(
      root,
      ['left', 'child', 'name'],
      store
    )

    assert_equal('shared', result)
    assert_equal([root, left, shared].map(&:cid).sort, blocks.map(&:cid).sort)
    refute_includes(blocks.map(&:cid), right.cid)
  end

  def test_returns_unselected_links_as_cids_without_loading_their_blocks
    shared = Seaboar.create_dag_cbor_block({ 'name' => 'shared' })
    left = Seaboar.create_dag_cbor_block({ 'child' => shared.cid, 'n' => 1 })
    right = Seaboar.create_dag_cbor_block({ 'child' => shared.cid, 'n' => 2 })
    root = Seaboar.create_dag_cbor_block({
      'left' => left.cid,
      'right' => right.cid
    })
    store = Seaboar::InMemoryBlockStore.new([root, left, right, shared])

    result, blocks = Seaboar.select_dag_cbor(root, [], store)

    expected = {
      'left' => left.cid,
      'right' => right.cid
    }
    assert_equal(expected, result)
    assert_equal(Set.new([root]), blocks)
  end

  def test_accepts_string_paths_with_numeric_array_indexes
    child = Seaboar.create_dag_cbor_block({ 'value' => 'found' })
    root = Seaboar.create_dag_cbor_block({ 'items' => [child.cid] })
    store = Seaboar::InMemoryBlockStore.new([root, child])

    result, blocks = Seaboar.select_dag_cbor(root, 'items/0/value', store)

    assert_equal('found', result)
    assert_equal([root, child], blocks.to_a)
  end

  def test_can_start_selection_from_a_cid
    child = Seaboar.create_dag_cbor_block({ 'value' => 7 })
    store = Seaboar::InMemoryBlockStore.new([child])

    result, blocks = Seaboar.select_dag_cbor(child.cid, ['value'], store)

    assert_equal(7, result)
    assert_equal(Set.new([child]), blocks)
  end

  def test_distinguishes_missing_links_from_missing_keys
    missing = Seaboar.create_dag_cbor_block({ 'present' => true })
    root = Seaboar.create_dag_cbor_block({ 'missing_link' => missing.cid })
    store = Seaboar::InMemoryBlockStore.new([root])

    missing_link_error = assert_raises(Seaboar::MissingLinkError) do
      Seaboar.select_dag_cbor(root, ['missing_link'], store)
    end
    assert_kind_of(Seaboar::MissingBlockError, missing_link_error)

    assert_raises(Seaboar::MissingBlockError) do
      store.get(missing.cid)
    end

    missing_key_error = assert_raises(Seaboar::PathNotFoundError) do
      Seaboar.select_dag_cbor(root, ['no_such_key'], store)
    end
    assert_match(/no_such_key/, missing_key_error.message)

    empty_array = Seaboar.create_dag_cbor_block([])
    store.put(empty_array)
    root_with_array = Seaboar.create_dag_cbor_block({ 'items' => empty_array.cid })
    store.put(root_with_array)
    out_of_range = assert_raises(Seaboar::PathNotFoundError) do
      Seaboar.select_dag_cbor(root_with_array, ['items', 0], store)
    end
    assert_match(/Array index/, out_of_range.message)
  end

  def test_reading_a_tampered_block_fails_digest_validation
    original = Seaboar.create_dag_cbor_block({ 'ok' => true })
    tampered_data = original.data.dup
    tampered_data.setbyte(-1, tampered_data.getbyte(-1) ^ 0x01)
    store = Seaboar::InMemoryBlockStore.new
    store.put_raw(original.cid, tampered_data)

    assert_raises(Seaboar::BlockIntegrityError) do
      store.get(original.cid)
    end

    root = Seaboar.create_dag_cbor_block({ 'bad' => original.cid })
    store.put(root)

    assert_raises(Seaboar::BlockIntegrityError) do
      Seaboar.select_dag_cbor(root, ['bad'], store)
    end

    result, blocks = Seaboar.select_dag_cbor(root, [], store)
    assert_equal({ 'bad' => original.cid }, result)
    assert_equal(Set.new([root]), blocks)
  end

  def test_supplied_root_block_is_also_digest_checked
    block = Seaboar.create_dag_cbor_block({ 'ok' => true })
    tampered_data = block.data.dup
    tampered_data.setbyte(-1, tampered_data.getbyte(-1) ^ 0x01)
    tampered = Seaboar::Block.new(block.cid, tampered_data)

    assert_raises(Seaboar::BlockIntegrityError) do
      Seaboar.select_dag_cbor(tampered, [], Seaboar::InMemoryBlockStore.new)
    end
  end

  def test_returns_a_structured_selection_object
    block = Seaboar.create_dag_cbor_block({ 'n' => 3 })
    store = Seaboar::InMemoryBlockStore.new([block])
    selection = Seaboar::DagCbor.select_block(block, ['n'], store)

    assert_kind_of(Seaboar::BlockSelection, selection)
    assert_equal(3, selection.value)
    assert_equal(Set.new([block]), selection.blocks)
    assert_equal([3, Set.new([block])], selection.to_a)
  end

  private

  def bytes(hexadecimal)
    hex_string_to_byte_string(hexadecimal)
  end

  def hex(string)
    string.unpack1('H*')
  end
end
