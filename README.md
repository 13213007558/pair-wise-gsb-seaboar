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

TODO: Write usage instructions here

### DAG-CBOR blocks

Seaboar can encode [IPLD DAG-CBOR](https://ipld.io/specs/codecs/dag-cbor/spec/) values and address the resulting blocks with CIDv1 multihashes (`dag-cbor` codec, SHA-256). Links are represented by `Seaboar::CID` and encoded with CBOR tag 42. No IPFS node or network connection is required.

```ruby
leaf = Seaboar::Block.create('value' => 42)
root = Seaboar::Block.create(
  'leaf' => leaf.cid,
  'same_leaf' => leaf.cid
)

store = Seaboar::MemoryBlockStore.new([leaf, root])
result = Seaboar::BlockService.new(store).select(root.cid, ['leaf', 'value'])

result.value   # 42
result.blocks  # [root, leaf], de-duplicated by CID
```

Path entries are hash keys or array indexes. A link is dereferenced only when the path continues through it, and every block fetched from the store is checked against its CID digest before decoding.

- A missing root raises `Seaboar::MissingBlockError`.
- A missing linked block raises `Seaboar::MissingLinkError`.
- A missing hash key raises `KeyError`.
- An out-of-range array index raises `IndexError`.
- Content whose digest does not match its CID raises `Seaboar::BlockIntegrityError`.

Any object implementing `fetch(cid)` can be injected as a block store. `fetch` may return a `Seaboar::Block`, encoded block bytes, or another object responding to `cid` and `data`.

## Contributing

Please read the design constraints above, and make sure your contributions fit within the goals of this project. If so, just follow the standard GitHub procedure for contributing:

1. Fork it
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create new Pull Request

Please ensure any functional or bugfix changes you make are covered by tests.
