require "zlib"

module BrowserReviewGate
  # Reads selected entries of a zip archive into memory, using only zlib. Made for Playwright traces,
  # which come from the agent and are untrusted: entry count, sizes and compression ratio are capped,
  # nothing is written to disk, and entry names are only compared, never used as paths.
  class ZipReader
    MAX_ENTRIES = 10_000
    MAX_ENTRY_BYTES = 50 * 1024 * 1024
    MAX_TOTAL_BYTES = 200 * 1024 * 1024
    MAX_RATIO = 200
    END_OF_DIRECTORY = "PK\x05\x06".b
    DIRECTORY_ENTRY = "PK\x01\x02".b
    LOCAL_ENTRY = "PK\x03\x04".b

    def initialize(path)
      @path = path
    end

    # Yields the name and content of every entry whose name the block's filter accepts.
    def each(filter)
      total = 0
      File.open(@path, "rb") do |file|
        directory(file).each do |entry|
          next unless filter.call(entry[:name])

          content = read(file, entry)
          total += content.bytesize
          raise Error, "trace is larger than #{MAX_TOTAL_BYTES / 1024 / 1024} MB uncompressed" if total > MAX_TOTAL_BYTES

          yield entry[:name], content
        end
      end
    end

    private

    def directory(file)
      size = file.size
      tail_size = [ size, 65_557 ].min
      file.seek(size - tail_size)
      tail = file.read(tail_size)
      at = tail.rindex(END_OF_DIRECTORY) or raise Error, "trace is not a zip archive"
      count, _directory_size, offset = tail[at + 10, 10].unpack("vVV")
      raise Error, "trace has too many entries" if count > MAX_ENTRIES

      file.seek(offset)
      Array.new(count) { directory_entry(file) }
    end

    def directory_entry(file)
      header = file.read(46)
      raise Error, "trace zip directory is damaged" unless header&.start_with?(DIRECTORY_ENTRY)

      method, compressed, uncompressed, name_length, extra_length, comment_length, offset =
        header.unpack("@10v@20VV@28vvv@42V")
      name = file.read(name_length).to_s.force_encoding(Encoding::UTF_8)
      file.seek(extra_length + comment_length, IO::SEEK_CUR)
      { name: name, method: method, compressed: compressed, uncompressed: uncompressed, offset: offset }
    end

    def read(file, entry)
      raise Error, "trace entry #{entry[:name][0, 80]} is too large" if entry[:uncompressed] > MAX_ENTRY_BYTES
      if entry[:compressed].positive? && entry[:uncompressed] / entry[:compressed] > MAX_RATIO
        raise Error, "trace entry #{entry[:name][0, 80]} is compressed suspiciously well"
      end

      position = file.pos
      file.seek(entry[:offset])
      local = file.read(30)
      raise Error, "trace zip entry is damaged" unless local&.start_with?(LOCAL_ENTRY)

      name_length, extra_length = local.unpack("@26vv")
      file.seek(name_length + extra_length, IO::SEEK_CUR)
      data = file.read(entry[:compressed]).to_s
      file.seek(position)
      content = case entry[:method]
                when 0 then data
                when 8 then inflate(data)
                else raise Error, "trace entry #{entry[:name][0, 80]} uses an unsupported compression method"
                end
      raise Error, "trace entry #{entry[:name][0, 80]} is not the size its header says" unless content.bytesize == entry[:uncompressed]

      content
    end

    # Stops as soon as the output passes the entry cap, so a lying header cannot exhaust memory.
    def inflate(data)
      inflater = Zlib::Inflate.new(-Zlib::MAX_WBITS)
      out = +""
      (0...data.bytesize).step(4096) do |offset|
        out << inflater.inflate(data.byteslice(offset, 4096))
        raise Error, "trace entry is larger than it says" if out.bytesize > MAX_ENTRY_BYTES
      end
      out << inflater.finish
      out
    rescue Zlib::Error
      raise Error, "trace entry is not valid deflate data"
    ensure
      inflater&.close
    end
  end
end
