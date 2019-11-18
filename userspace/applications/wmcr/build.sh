build() {
  pngflags="-I$opt_toolsdir/include -L$opt_toolsdir/lib $script_dir/painter/c/alpha_blend.c $script_dir/painter/c/png.c -lspng -lz -lm -msse2"
  LDFLAGS="$pngflags" $script_dir/compile $script_dir/wmcr.cr $build_dir/wmcr
  $script_dir/compile $script_dir/windem.cr $build_dir/windem
  $script_dir/compile $script_dir/desktop.cr $build_dir/desktop
  $script_dir/compile $script_dir/cterm.cr $build_dir/cterm
  $script_dir/compile $script_dir/cbar.cr $build_dir/cbar
  LDFLAGS="$pngflags" $script_dir/compile $script_dir/pape.cr $build_dir/pape
}

install() {
  for i in $script_dir/*.cr; do
    sudo cp $build_dir/$(basename $i .cr) $install_dir/bin
  done
}
