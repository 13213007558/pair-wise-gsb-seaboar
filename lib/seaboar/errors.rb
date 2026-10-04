module Seaboar
  class Error < StandardError; end
  class EncodingError < Error; end
  class DecodingError < Error; end
  class InvalidCIDError < Error; end
  class InvalidBlockError < Error; end
  class BlockIntegrityError < InvalidBlockError; end
  class MissingBlockError < Error; end
  class MissingLinkError < MissingBlockError; end
  class PathNotFoundError < Error; end
  class PathResolutionError < Error; end
  class InvalidPathError < Error; end
end
