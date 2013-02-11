require 'fileutils'
require 'tmpdir'
require 'rpm2gem/rpm'
require 'logging'

module Rgsyn

  class InvalidPackageFormatError < StandardError; end

  module Helpers
  
    # Translate operating system and CPU architecture notation into Mock
    # config name (e.g. 'fc16' and 'i386' to 'fedora-16-i386').
    #
    def self.mock_config(os, arch = ARCH.first)
      prefix =
        case os
        when 'fc14' then 'fedora-14'
        when 'fc15' then 'fedora-15'
        when 'fc16' then 'fedora-16'
        when 'fc17' then 'fedora-17'
        else raise(RuntimeError, "Unable to translate #{os} and #{arch} "\
                                 "to fitting mock config")
        end
      suffix =
        case arch
        when 'i386', 'i586', 'i686' then 'i386'
        else arch
        end
      "#{prefix}-#{suffix}"
    end

    # Copy a file without regard about the destination; will be copied to tmp
    # directory.
    #
    def self.cp_anonymous(src_file)
      src_name = File.basename(src_file)
      ext = 0
      dst_file = "#{Dir.tmpdir}/#{src_name}"
      
      loop do
        begin
          File.new(dst_file, File::CREAT|File::EXCL)
          break
        rescue Errno::EEXIST
          dst_file = "#{Dir.tmpdir}/#{src_name}.#{ext}"
          ext += 1
        end
      end
      
      FileUtils.cp(src_file, dst_file)
      dst_file
    end

    # Make dir without regard about its placement. Will be created in tmp
    # directory and should be deleted, when no longer needed!
    #
    def self.mkdir_anonymous
      Dir.mktmpdir
    end
    
    def self.init_log(path)
      FileUtils.mkdir_p(File.dirname(path))
      FileUtils.rm_f(path)
      Logging.logger.root.appenders = Logging.appenders.file(path)
    end
    
  end
  
end
