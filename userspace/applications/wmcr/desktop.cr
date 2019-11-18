startup = [
  ["pape", "/hd0/share/papes/default.png"],
  ["cbar"],
  # ["cterm"],
]
startup.each do |args|
  program = args.shift.not_nil!
  Process.new program, args,
    input: Process::Redirect::Inherit,
    output: Process::Redirect::Inherit,
    error: Process::Redirect::Inherit
end
