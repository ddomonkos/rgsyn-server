require 'rgsyn-server/helpers'

module Rgsyn

  class Specfile
  
    attr_reader :content
    
    EXCLUDE_DIRS = %w(ext test tests example examples extra tasks)
  
    def initialize(content)
      @content = content
    end
    
    def self.generate(gemfile, os)
      content = `gem2rpm --template #{self.template(os)} #{gemfile}`
      raise "Failed to generate specfile: #{content}" if not $?.success?
      
      tmpdir = Helpers.mkdir_anonymous
      gemtmpdir = Helpers.mkdir_anonymous
      begin
        #it is necessary to add .gem extension into the filename, otherwise
        #gem client does not realize it is a local file...
        FileUtils.cp(gemfile, "#{gemtmpdir}/gem.gem")
        `gem unpack #{gemtmpdir}/gem.gem --target #{tmpdir}`
        raise "Failed to unpack gem" if not $?.success?
	      Dir.chdir(Dir["#{tmpdir}/*"].first) do
	        files = Dir['*']
	        files.select! do |entry|
	          ! EXCLUDE_DIRS.include?(entry) &&
	          (! File.file?(entry) || File.extname(entry) == '.rb')
	        end
	        files.map! { |x| "%{geminstdir}/#{x}\n" }
          content.gsub!(/(^%files\s*\n)/m, "\\1#{files.join}")
        end
      ensure
        FileUtils.rm_rf(gemtmpdir)
        FileUtils.rm_rf(tmpdir)
      end
      
      self.new(content)
    end
    
    def license=(val)
      @content.gsub!(/^(License:\s*).+$/, "\\1#{val}")
    end
    
    def add_dependencies(deps, bdeps)
      unless deps.empty?
        deps = deps.map{|x| "Requires: #{x}\n"}.join
        @content.gsub!(/(.*^Requires:[^\n]*\n)(.*?%package)/m, "\\1#{deps}\\2")
      end
      
      unless bdeps.empty?
        bdeps = bdeps.map{|x| "BuildRequires: #{x}\n"}.join
        @content.gsub!(/(.*^BuildRequires:[^\n]*\n)(.*?%package)/m,
                       "\\1#{bdeps}\\2")
      end
    end
    
    private
  
    def self.template(os)
      template =
        if os == 'fc17'
          'fedora-17-rawhide.spec.erb.fixed'
        else
          'fedora.spec.erb.fixed'
        end
      "gem2rpm/templates/#{template}"
    end
  
  end
  
end
