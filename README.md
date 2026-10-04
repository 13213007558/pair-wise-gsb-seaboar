# Seaboar

Seaboar is a pure Ruby implementation of a CBOR encoder / decoder. CBOR is Concise Binary Object Representation, a schemaless, efficient alternative to JSON. CBOR is defined by [RFC 7049](https://tools.ietf.org/html/rfc7049).

Seaboar is a just-for-fun project of the author. If you're looking for a Ruby CBOR implementation for use in production, you're probably in the wrong place. Check out the [cbor-ruby](https://github.com/cabo/cbor-ruby) project for a much faster and more complete implementation.

Seaboar's design constraints/goals are as follows:

1. Pure Ruby (no C or Java extensions)
2. No (runtime) dependencies
3. Encoding support on-par with common Ruby JSON libraries

Note that 'performance' is not on that list. If you're looking for good performance, you should probably use another implementation. Note also that there are some CBOR features (particularly on the encoding side) that will not be implemented in Seaboar. These include support for encoding to half-width floats, (though decoding them is supported), as well as support for encoding streaming strings, arrays, and hashes (although again, decoding these objects is supported).

## Installation

Add this line to your application's Gemfile:

    gem 'seaboar'

And then execute:

    $ bundle

Or install it yourself as:

    $ gem install seaboar

## Usage

### CBOR

```ruby
require 'seaboar'

encoded = Seaboar.encode({ 'answer' => 42 })
Seaboar.decode(encoded)
```

### DAG-CBOR blocks

`Seaboar` can encode [IPLD DAG-CBOR](https://ipld.io/specs/codecs/dag-cbor/spec/) blocks, create CIDv1 / SHA-256 CIDs for them, and resolve paths through links. DAG-CBOR values are restricted to the IPLD data model: integers, floats, booleans, `nil`, byte and text strings, arrays, maps, and `Seaboar::CID` links. Maps use text keys and deterministic length-then-byte order; tags and indefinite-length CBOR values are rejected except for CID tag 42.

```ruby
require 'seaboar'

store = Seaboar::InMemoryBlockStore.new

child = Seaboar.create_dag_cbor_block({ 'value' => 'hello' })
root = Seaboar.create_dag_cbor_block({
  'items' => [child.cid]
})

store.put(root)
store.put(child)

selection = Seaboar.select_dag_cbor(root, ['items', 0, 'value'], store)
selection.value  # => "hello"
selection.blocks # => #<Set: {root block, child block}>
```

A slash-separated path is also accepted (`'items/0/value'`). Numeric path segments select array indexes; all other segments select map keys. Any object responding to `get(cid)` and returning a `Seaboar::Block` or binary string can be injected as the block store. Every fetched block is checked against its CID digest before decoding.

- `Seaboar::MissingLinkError` (a subclass of `Seaboar::MissingBlockError`) means a referenced block was absent from the store.
- `Seaboar::PathNotFoundError` means an array index or map key does not exist.
- `Seaboar::PathResolutionError` means the path segment cannot be applied to the current node.
- `Seaboar::BlockIntegrityError` means the stored bytes do not hash to the requested CID.

`InMemoryBlockStore#put_raw` is available for tests that need to insert deliberately corrupted bytes. No IPFS node or network connection is required.

## Contributing

Please read the design constraints above, and make sure your contributions fit within the goals of this project. If so, just follow the standard GitHub procedure for contributing:

1. Fork it
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create new Pull Request

Please ensure any functional or bugfix changes you make are covered by tests.
