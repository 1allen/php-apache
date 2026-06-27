# Stage ImageMagick With DESTDIR

ImageMagick should be configured with its runtime prefix as `/usr/local` and
installed into a temporary staging root with `make install DESTDIR=/tmp/imgck`.
This keeps the copied artifact paths aligned with their runtime location while
still allowing the final image to copy only the staged `/usr/local` tree from
the builder stage.

