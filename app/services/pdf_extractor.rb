require "pdf/reader"

# Extracts text from a PDF, page by page.
class PdfExtractor
  # io_or_path: a File, StringIO, or path string.
  # Returns Array of { page_number:, text: }.
  def self.extract(io_or_path)
    reader = PDF::Reader.new(io_or_path)
    reader.pages.each_with_index.map do |page, idx|
      { page_number: idx + 1, text: page.text.to_s }
    end
  rescue PDF::Reader::MalformedPDFError, PDF::Reader::UnsupportedFeatureError => e
    raise "Could not read PDF: #{e.message}"
  end
end
