# Splits extracted document text into overlapping chunks suitable for embedding.
#
# Uses a simple word-based sliding window. Overlap preserves context across
# chunk boundaries so retrieval doesn't lose sentences that straddle a split.
class TextChunker
  Chunk = Struct.new(:content, :page_number, :position, keyword_init: true)

  DEFAULT_CHUNK_SIZE = 200   # words per chunk
  DEFAULT_OVERLAP    = 40    # words shared with the previous chunk

  def initialize(chunk_size: DEFAULT_CHUNK_SIZE, overlap: DEFAULT_OVERLAP)
    raise ArgumentError, "overlap must be smaller than chunk_size" if overlap >= chunk_size

    @chunk_size = chunk_size
    @overlap = overlap
  end

  # pages: Array of { page_number:, text: }
  # Returns Array<Chunk> with global positions.
  def call(pages)
    position = 0
    chunks = []

    pages.each do |page|
      words = page[:text].to_s.split(/\s+/).reject(&:empty?)
      next if words.empty?

      start = 0
      while start < words.length
        slice = words[start, @chunk_size]
        chunks << Chunk.new(
          content: slice.join(" "),
          page_number: page[:page_number],
          position: position
        )
        position += 1
        break if start + @chunk_size >= words.length

        start += (@chunk_size - @overlap)
      end
    end

    chunks
  end
end
