struct Char
  # The character representing the end of a C string.
  ZERO = '\0'

  # The maximum character.
  MAX = 0x10ffff.unsafe_chr

  # The maximum valid codepoint for a character.
  MAX_CODEPOINT = 0x10ffff

  # The replacement character, used on invalid UTF-8 byte sequences.
  REPLACEMENT = '\ufffd'

  def ===(other)
    self == other
  end

  def bytesize
    c = ord
    if c < 0x80
      # 0xxxxxxx
      1
    elsif c <= 0x7ff
      # 110xxxxx  10xxxxxx
      2
    elsif c <= 0xffff
      # 1110xxxx  10xxxxxx  10xxxxxx
      3
    elsif c <= MAX_CODEPOINT
      # 11110xxx  10xxxxxx  10xxxxxx  10xxxxxx
      4
    else
      0
    end
  end

  def each_byte : Nil
    # See http://en.wikipedia.org/wiki/UTF-8#Sample_code

    c = ord
    if c < 0x80
      # 0xxxxxxx
      yield c.to_u8
    elsif c <= 0x7ff
      # 110xxxxx  10xxxxxx
      yield (0xc0 | c >> 6).to_u8
      yield (0x80 | c & 0x3f).to_u8
    elsif c <= 0xffff
      # 1110xxxx  10xxxxxx  10xxxxxx
      yield (0xe0 | (c >> 12)).to_u8
      yield (0x80 | ((c >> 6) & 0x3f)).to_u8
      yield (0x80 | (c & 0x3f)).to_u8
    elsif c <= MAX_CODEPOINT
      # 11110xxx  10xxxxxx  10xxxxxx  10xxxxxx
      yield (0xf0 | (c >> 18)).to_u8
      yield (0x80 | ((c >> 12) & 0x3f)).to_u8
      yield (0x80 | ((c >> 6) & 0x3f)).to_u8
      yield (0x80 | (c & 0x3f)).to_u8
    end
  end

  def to_s(io)
    c = self.ord.to_u8
    io.write Bytes.new(pointerof(c), 1)
  end
end
