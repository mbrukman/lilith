#include <stdio.h>
#include <syscalls.h>
#include <spng.h>

static int read_fn(spng_ctx *ctx, void *user, void *dest, size_t length) {
  int fd = *(int*)user;
  ssize_t retval = read(fd, dest, length);
  if(retval > 0) {
    return 0;
  } else if (retval == EOF) {
    return SPNG_IO_EOF;
  } else {
    return SPNG_IO_ERROR;
  }
}

spng_ctx *painter_open_png(int *fd, int *width, int *height) {
  spng_ctx *ctx = spng_ctx_new(0);
  spng_set_png_stream(ctx, read_fn, fd);
  struct spng_ihdr ihdr = {0};
  spng_get_ihdr(ctx, &ihdr);
  *width = (int)ihdr.width;
  *height = (int)ihdr.height;
  return ctx;
}

void painter_read_buffer(spng_ctx *ctx, unsigned char *buffer, size_t size) {
  spng_decode_image(ctx, buffer, size, SPNG_FMT_RGBA8, SPNG_DECODE_TRNS);
}

void painter_dealpha(unsigned char *buffer, size_t size) {
  for(size_t i = 0; i < size; i += 4) {
    unsigned char r = buffer[i + 0];
    unsigned char g = buffer[i + 1];
    unsigned char b = buffer[i + 2];
    buffer[i + 0] = b;
    buffer[i + 1] = g;
    buffer[i + 2] = r;
    buffer[i + 3] = 0;
      }
}
