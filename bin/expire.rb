require 'bundler/setup'
require 'trollop'
require 'pathname'
require_relative '../lib/constants'

opts = Trollop::options do
  opt :file, "Locations of files relative to #{UPLOADS} directory",
    :required => true, :type => :strings, :multi => false
end

# Validate
paths = opts[:file].map {|f| Pathname.new(File.join(UPLOADS, f)).cleanpath}
paths.each do |p|
  raise StandardError, "File does not exist #{p}." unless p.exist?
  raise StandardError, "Can not expire symlinks #{p}." if p.symlink?
end

# Create the directory structure in TOENCRYPT and add the symlinks
opts[:file].each do |f|
  symlink_source = Pathname.new(File.join(TOENCRYPT, f)).cleanpath
  symlink_source_dir = symlink_source.dirname
  FileUtils.mkdir_p(symlink_source_dir) unless symlink_source_dir.exist?
  symlink_target = Pathname.new(File.join(File.expand_path(File.dirname __FILE__), '..', UPLOADS, f)).cleanpath
  FileUtils.ln_s(symlink_target, symlink_source)
end