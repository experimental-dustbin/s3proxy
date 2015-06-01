require 'bundler/setup'
require 'pathname'
require 'fileutils'
require 'openssl'
require 'trollop'
require_relative '../lib/constants'

opts = Trollop::options do
  opt :procs, "Number of processes that will be uploading to S3",
    :required => true, :type => :int, :multi => false
end

files = Dir[File.join(TOENCRYPT, '**', '*')].reject {|f| File.directory?(f)}
key_number = Pathname.new(PRIVATEKEY).readlink.to_s
key = File.read(File.join(KEYS, "#{key_number}"))
# Acquire lock and encrypt the file into encrypting folder and then atomically move it into place
pids = files.each_slice(files.length / opts[:procs]).map do |slice|
  fork do
    slice.each do |filename|
      path = Pathname.new(filename).cleanpath
      if !path.directory?
        # All the paths
        encrypting_path = Pathname.new(path.to_s.sub(TOENCRYPT, File.join(ENCRYPTING, key_number))).cleanpath
        encrypted_path = Pathname.new(path.to_s.sub(TOENCRYPT, File.join(ENCRYPTED, key_number))).cleanpath
        upload_path = Pathname.new(path.to_s.sub(TOENCRYPT, UPLOADS)).cleanpath
        s3path = Pathname.new(File.join(BUCKET, encrypted_path.to_s.sub(ENCRYPTED, ''))).cleanpath
        iv_path = Pathname.new("#{encrypted_path}-iv").cleanpath
        lock = Pathname.new(path.to_s.sub(TOENCRYPT, LOCKS)).cleanpath
        # All the directories
        directories = [encrypting_path.dirname, encrypted_path.dirname, iv_path.dirname, lock.dirname]
        directories.each {|dir| FileUtils.mkdir_p(dir) unless dir.exist?}
        # Acquire the lock and then process the file
        File.open(lock, File::RDWR | File::CREAT, 0644) do |f|
          f.flock(File::LOCK_EX)
          if CONFIG['encryption']
            cipher = OpenSSL::Cipher.new('aes-256-gcm')
            cipher.encrypt
            cipher.key = key
            iv = cipher.random_iv
            File.open(iv_path, 'w') {|f| f.write(iv)}
            data = File.read(path)
            encrypted_data = cipher.update(data) + cipher.final
            File.open(encrypting_path, 'w') {|f| f.write(encrypted_data)}
            FileUtils.mv(encrypting_path, encrypted_path, :force => true)
          else
            bin_dir = File.expand_path(File.dirname __FILE__)
            link_file = File.join(bin_dir, '..', encrypted_path)
            abs_path = File.join(bin_dir, '..', path)
            FileUtils.ln_s(abs_path, link_file, :force => true)
          end
        end
        # Upload encrypted artifact to S3 and and remove it from file system
        if CONFIG['encryption']
          `s3cmd put -F '#{encrypted_path}' 's3://#{s3path}'`
          if $?.exitstatus > 0
            raise StandardError, "Something went wrong when uploading #{encrypted_path} to #{s3path}"
          end
          `s3cmd put -F '#{iv_path}' 's3://#{s3path}-iv'`
          if $?.exitstatus > 0
            raise StandardError, "Something went wrong when uploading IV #{iv_path}."
          end
        else
          `s3cmd put -F '#{encrypted_path}' 's3://#{s3path}'`
          if $?.exitstatus > 0
            raise StandardError, "Something went wrong when uploading #{encrypted_path} to #{s3path}."
          end
        end
        # Now leave a marker at the old upload place
        FileUtils.rm(encrypted_path, :force => true)
        FileUtils.rm(path, :force => true)
        FileUtils.rm(iv_path, :force => true)
        FileUtils.rm(upload_path, :force => true)
        FileUtils.ln_s(s3path, upload_path, :force => true)
      end
    end
  end
end
pids.each {|pid| Process.wait(pid)}
