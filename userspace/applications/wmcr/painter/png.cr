module Painter
  extend self

  lib SPNG
    fun painter_open_png(fd : LibC::Int*, width : LibC::Int*, height : LibC::Int*) : Void*
    fun painter_read_buffer(png_ptr : Void*, buffer : UInt8*, size : LibC::SizeT)
    fun painter_dealpha(buffer : UInt8*, size : LibC::SizeT)
    fun spng_ctx_free(png_ptr : Void*)
  end

  struct Image
    getter width, height, bytes
    def initialize(@width : Int32, @height : Int32, @bytes : Bytes)
    end
  end

  private def internal_load_png(filename, &block)
    if (fd = LibC.open(filename, LibC::O_RDONLY)) < 0
      return
    end
    width = 0
    height = 0
    png_ptr = SPNG.painter_open_png pointerof(fd), pointerof(width), pointerof(height)
    yield Tuple.new(width, height, png_ptr)
    SPNG.spng_ctx_free png_ptr
    LibC.close fd
  end

  def load_png(filename : String, bytes : Bytes)
    internal_load_png(filename) do |width, height, png_ptr|
      SPNG.painter_read_buffer png_ptr, bytes.to_unsafe, bytes.size
    end
  end

  def load_png(filename : String) : Image?
    img = nil
    internal_load_png(filename) do |width, height, png_ptr|
      bytes = Bytes.new(width * height * 4)
      SPNG.painter_read_buffer png_ptr, bytes.to_unsafe, bytes.size
      img = Image.new width.to_i32, height.to_i32, bytes
    end
    img
  end

  def dealpha(bytes : Bytes)
    SPNG.painter_dealpha bytes.to_unsafe, bytes.size
  end

end
