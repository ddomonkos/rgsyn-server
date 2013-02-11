require 'rgsyn-server/entity/package'
require 'rgsyn-server/repository/repo_mixin'
require 'rgsyn-server/entity/user'
require 'rgsyn-server/specfile'
require 'rgsyn-server/helpers'
require 'ohm'
require 'resque'
require 'fileutils'
require 'logging'

module Rgsyn

  # The primary entity of the application. A Library entity is defined by the
  # name and version of the RubyGems library it represents.
  #
  # A note regarding naming conventions: Packages (_gem_, _rpm_, _srpm_) are
  # normally represented in the form of a Package entity instead of a bare
  # file(path), unless stated otherwise (such as _gemfile_).
  #
  class Library < Ohm::Model
    
    attribute :name_version
    attribute :created_on
    
    unique :name_version
    
    reference :owner, User
    list :packages, Package
    
    #used to separate Mock logs of individual Mock calls (unique folder name)
    counter :_mock_logs_id

    def self.create(p = {})
      library = super(p)
      
      #prepare user log (brief.log)
      FileUtils.mkdir_p(library.logdir)
      FileUtils.touch("#{library.logdir}/brief.log")
      
      #automatically set timestamp
      library.update(:created_on => Time.now)
      library
    end
    
    def id=(value)
      super(value)
      
      #update @logger logfile
      @logger = Logging.logger[self]
      @logger.appenders = Logging.appenders.file("#{logdir}/detailed.log")
    end
    
    # Convert Gem to RPM. Parameter _os_ should correspond the operating system
    # for which the _specfile_ was generated.
    #
    def gem2rpm(os, specfile, options = {})
      @logger.info('Gem->RPM: Start!')
      begin
        gem = packages.detect { |package| package.type == 'gem' }
        raise 'Library has no gem package!' if gem.nil?
        build_dir = Helpers.mkdir_anonymous
        
        begin
          gemspec = gem.lock { Gem::Format.from_file_by_path(gem.file).spec }
          gemfile = "#{build_dir}/#{gemspec.file_name}"
          gem.lock { FileUtils.cp(gem.file, gemfile) }
         
          specfile_path = "#{build_dir}/rubygem-#{gemspec.name}.spec"
          File.open(specfile_path, 'w') { |f| f.write(specfile.content) }
          
          @logger.info('Gem->RPM: Success! (needs to be built now)')
          async_build_and_rebuild(gem, os, build_dir, options)
        rescue => ex
          FileUtils.rm_rf(build_dir)
          raise ex
        end
        
        log("Build requested. (#{os}, source)")
      rescue => ex
        @logger.error("Gem->RPM: Failure! #{ex.to_s}")
        raise ex
      end
    end
    
    # Convert RPMs to Gem. Parameter _os_ serves as an identification for RPMs
    # which should be used as the source in the conversion process (as there may
    # be RPMs present for numerous operating systems).
    #
    def rpm2gem(os, options = {})
      @logger.info('RPM->Gem: Start!')
      begin
        rpms = packages.select do |p|
          [Package::SRPM, Package::RPM].include?(p.type) &&
          Rpm2Gem::Rpm.os(p.file) == os
        end
        
        raise 'There are no satisfying RPM packages!' if rpms.empty?
        if rpms.select{ |p| p.type == 'rpm' }.empty?
          raise 'There are no binary RPM packages!'
        end
          
        files = rpms.map { |p| p.lock { Helpers.cp_anonymous(p.file) } }
        result_dir = Helpers.mkdir_anonymous
        
        begin
          IO.popen("cd #{result_dir} && " \
                   "rpm2gem --verbose #{files.join(' ')} 2>&1") { |p|
            p.each { |l| @logger.info("RPM->Gem: rpm2gem script: #{l.chomp}") }}
          raise 'Conversion failed!' if not $?.success?
          gemfile = Helpers.cp_anonymous(Dir.glob("#{result_dir}/*.gem").first)
        ensure
          files.each { |f| FileUtils.rm_f(f) }
          FileUtils.rm_rf(result_dir)
        end
        
        gem = Package.create(:type => 'gem',
                             :file => gemfile,
                             :generated => true,
                             :force => options[:force] || false)
        rpms.each { |p| p.children.push(gem) }
        packages.push(gem)
        
        @logger.info('RPM->Gem: Success!')
        log("RPM->Gem conversion <g>succeeded</g>! (#{os})")
        
      rescue Repository::NameConflictError => ex
        @logger.error("RPM->Gem: Halted, package already exists! (#{ex.to_s})")
        log("RPM->Gem conversion <y>halted</y>! (#{os})")
        raise ex
      rescue => ex
        @logger.error("RPM->Gem: Failure! #{ex.to_s}")
        log("RPM->Gem conversion <r>failed</r>! (#{os})")
        raise ex
      end
    end
    
    # Build SRPM package using a given build directory (parameter build_dir)
    # that contains the specfile, as well as all its source files. Parameter 
    # _gem_ is used to identify the Gem package, from which the SRPM is being
    # built (for further reference). Parameter _os_ is the target operating
    # system of the resulting SRPM.
    #
    # Possible options are:
    #   :force - whether resulting package should override an existing one.
    #   :continue - this should be only used if _rebuild is called immediately
    #               after (on the SRPM that results from this operation, and
    #               within the same process). The purpose of this is to avoid
    #               the need to create the same Mock environment twice, first
    #               for _build (SRPM) and then for _rebuild (binary RPMs).
    #   :arch - should be used only with :continue, and should be the same
    #           as the _arch_ used on _rebuild.
    #
    def build(gem, os, build_dir, options = {})
      @logger.info('Build: Start!')
      begin
        #build (Mock)
        specfile_path = Dir.glob("#{build_dir}/*.spec").first
        result_dir = Helpers.mkdir_anonymous
        begin
          @logger.info('Build: Starting Mock!')
          IO.popen("mock --root #{Helpers.mock_config(os)} \
                         --resultdir #{result_dir} \
                         --uniqueext #{$$} \
                         #{options[:continue] ?
                           "--no-cleanup-after --arch #{options[:arch]}" : 
                           ""} \
                         --buildsrpm \
                         --spec #{specfile_path} \
                         --sources #{build_dir} 2>&1"){|o| o.each{|l| print l}}
          mock_id = incr :_mock_logs_id
          FileUtils.mkdir_p("#{logdir}/#{mock_id}")
          FileUtils.mv(Dir.glob("#{result_dir}/*.log"), "#{logdir}/#{mock_id}")
          
          raise "Mock failed! (logs id: #{mock_id})" if not $?.success?
          @logger.info("Build: Mock build ok! (logs id: #{mock_id})")
          
          file = Helpers.cp_anonymous(Dir.glob("#{result_dir}/*.src.rpm").first)
        ensure
          FileUtils.rm_rf(result_dir)
        end
        
        #update entities (database)
        srpm = Package.create(:type => Package::SRPM,
                              :file => file,
                              :generated => true,
                              :force => options[:force] || false)
        gem.children.push(srpm)
        packages.push(srpm)
        
        @logger.info('Build: Success!')
        log("Build <g>succeeded</g>! (#{os}, source)")
      
      rescue Repository::NameConflictError => ex
        @logger.error("Build: Halted, package already exists! (#{ex.to_s})")
        log("Build <y>halted</y>! (#{os}, source) Package already exists!")
        raise ex
      rescue => ex
        @logger.error("Build: Failure! #{ex.to_s}")
        log("Build <r>failed</r>! (#{os}, source)")
        raise ex
      ensure
        FileUtils.rm_rf(build_dir)
      end
      
      srpm
    end
    
    # Rebuild the specified SRPM. This creates binary RPMs. Parameter _arch_
    # is the CPU architecture which the resulting RPMs should target. Possible
    # options include :force and :continue. See _build for explanation.
    #
    def rebuild(srpm, arch, options = {})
      @logger.info('Rebuild: Start!')
      begin
        file = srpm.lock { Helpers.cp_anonymous(srpm.file) }
        result_dir = Helpers.mkdir_anonymous
        
        begin
          os = Rpm2Gem::Rpm.os(file)
          config = Helpers.mock_config(os, arch)

          #rebuild (Mock)
          @logger.info('Rebuild: Starting Mock!')
          IO.popen("mock --root #{config} \
                         --arch #{arch} \
                         --resultdir #{result_dir} \
                         --uniqueext #{$$} \
                         #{options[:continue] ? '--no-clean' : ''} \
                         --rebuild #{file} 2>&1"){|o| o.each{|l| print l}}
          mock_id = incr :_mock_logs_id
          FileUtils.mkdir_p("#{logdir}/#{mock_id}")
          FileUtils.mv(Dir.glob("#{result_dir}/*.log"), "#{logdir}/#{mock_id}")
          
          raise "Mock failed! (logs id: #{mock_id})" if not $?.success?
          @logger.info("Rebuild: Mock build ok! (logs id: #{mock_id})")
          
          files = Dir.glob("#{result_dir}/*.rpm").select {|f|
                    !f.end_with?('.src.rpm')}
          files.map! { |f| Helpers.cp_anonymous(f) }
        ensure
          FileUtils.rm_f(file)
          FileUtils.rm_rf(result_dir)
        end
        
        #update entities (database)
        failed = 0
        files.each do |file|
          begin
            rpm = Package.create(:type => 'rpm',
                                 :file => file,
                                 :generated => true,
                                 :force => options[:force] || false)
            srpm.children.push(rpm)
            packages.push(rpm)
          rescue Repository::NameConflictError => ex
            @logger.error("Build: Warning, package already exists! #{ex.to_s}")
            failed += 1
          end
        end
        
        @logger.info('Rebuild: Success!')
        if failed == 0
          log("Build <g>succeeded</g>! (#{os}, #{arch})")
        else
          log("Build <y>succeeded</y>! (#{os}, #{arch})")
        end
        
      rescue => ex
        @logger.error("Rebuild: Failure! #{ex.to_s}")
        log("Build <r>failed</r>! (#{os}, #{arch})")
        raise ex
      end
    end
    
    # _Build followed by _rebuild, creating SRPM with binary RPMs for all
    # supported architectures (unless noarch). Exists mainly for asynchronous
    # purposes.
    #
    def build_and_rebuild(gem, os, build_dir, options = {})
      srpm = build(gem, os, build_dir, options.merge(:continue => true,
                                                     :arch => ARCH.first))
      
      noarch = srpm.lock { Rpm2Gem::Rpm.noarch?(srpm.file) }
      if not noarch
        #build for all but first
        ARCH[1..-1].each do |arch|
          Resque.push('mock_build',
                      :class => self.class.to_s,
                      :args => ['rebuild', id, srpm.id, arch, options])
          log("Build requested. (#{os}, #{arch})")
        end
      end
      
      #build for first arch (continue)
      log("Build requested. (#{os}, #{ARCH.first})")
      rebuild(srpm, ARCH.first, options.merge(:continue => true))
    end
    
    # _Rebuild followed by _rpm2gem. Exists mainly for asynchronous purposes
    # and is useful when the library does not have binary RPMs (yet) which are
    # necessary for the rpm2gem conversion.
    #
    def rebuild_and_rpm2gem(srpm, options = {})
      rebuild(srpm, ARCH.first, options)
      os = srpm.lock {Rpm2Gem::Rpm.os(srpm.file)}
      log("RPM->Gem conversion requested. (#{os})")
      rpm2gem(os, options)
    end
    
    def async_build(gem, os, build_dir, options = {})
      Resque.push('mock_build',
                  :class => self.class.to_s,
                  :args => ['build', id, gem.id, os, build_dir, options])
    end
    
    def async_rebuild(srpm, arch, options = {})
      noarch = srpm.lock { Rpm2Gem::Rpm.noarch?(srpm.file) }
      if noarch
        Resque.push('mock_build',
                    :class => self.class.to_s,
                    :args => ['rebuild', id, srpm.id, ARCH.first, options])
      else
        ARCH.each do |arch|
          Resque.push('mock_build',
                      :class => self.class.to_s,
                      :args => ['rebuild', id, srpm.id, arch, options])
        end
      end
    end
    
    def async_build_and_rebuild(gem, os, build_dir, options = {})
      Resque.push('mock_build',
                  :class => self.class.to_s,
                  :args => ['build_and_rebuild', id, gem.id, os, build_dir,
                            options])
    end

    def async_rebuild_and_rpm2gem(srpm, options = {})
      Resque.push('mock_build',
                  :class => self.class.to_s,
                  :args => ['rebuild_and_rpm2gem', id, srpm.id, options])
    end
    
    # Extract the name and version of the library in the specified package.
    # Type is the of the package (Gem or RPM).
    #
    def self.name_version(type, file)
      if type == Package::GEM
        begin
          gemformat = Gem::Format.from_file_by_path(file)
          raise InvalidPackageFormatError if gemformat.nil?
          gemspec = gemformat.spec
          "#{gemspec.name}-#{gemspec.version}"
        rescue Gem::Package::FormatError
          raise Package::InvalidFileError
        end
      else
        name, version = Rpm2Gem::Rpm.name_version(file)
        "#{name.gsub(/^rubygem-/, '')}-#{version}"
      end
    end
    
    # Returns library's log directory.
    #
    def logdir
      File.expand_path("../../../log/library/#{id}", File.dirname(__FILE__))
    end
    
    # Log a message into the user log (brief.log). User log's purpose is to
    # collect information about various manipulation operations made by users.
    #
    def log(message)
      open("#{logdir}/brief.log", 'a') { |f| f.puts "#{Time.now}: #{message}" }
    end
    
    # Generate an RPM specfile from the Gem. Parameter _os_ specifies for which 
    # operating system the specfile is.
    #
    def generate_specfile(os)
      gem = packages.detect { |package| package.type == 'gem' }
      raise 'Library has no gem package!' if gem.nil?
      file = gem.lock { Helpers.cp_anonymous(gem.file) }
      
      begin
        Specfile.generate(file, os) #this is kinda slow
      ensure
        FileUtils.rm_f(file)
      end
    end
    
    private
    
    # Internal method for the Resque library.
    #
    def self.perform(method, library_id, *args)
      Logging.logger.root.appenders = Logging.appenders.stdout
Logging.logger[self].info("Start: #{Time.now}")
      args[0] = Package[args[0]] #gem.id/srpm.id
      Library[library_id].send(method.to_sym, *args)
Logging.logger[self].info("End: #{Time.now}")
    end
    
  end
  
end
