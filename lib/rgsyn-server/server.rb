require 'rgsyn-server/helpers'
require 'rgsyn-server/entity/package'
require 'rgsyn-server/entity/library'
require 'rgsyn-server/entity/user'
require 'sinatra'
require 'logging'
require 'json'

module Rgsyn
  
  class Server < Sinatra::Base

    set :public_folder, File.expand_path('../../public',
                          File.dirname(__FILE__))
    set :show_exceptions, false
    
    set(:auth) do |level|
      condition do
        error 401, 'Authentication required!' if @user.nil?
        restrict!(level)
        true
      end
    end
    
    before do
      content_type 'text/plain'
      _request = Rack::Auth::Basic::Request.new(request.env)
      @user = nil
      
      if _request.provided? && _request.basic? && _request.credentials
        @user = User.with(:username, _request.credentials[0])
        error 401, 'Incorrect username or password!' if @user.nil?
        
        if not @user.auth?(_request.credentials[1])
          error 401, 'Incorrect username or password!'
        end
      end
    end
    
    before %r{/library/([^/]+)/?.*} do |ident|
      @library = find_library(ident)
      error 400, 'No matching library found!' if @library.nil?
    end
    
    # Get server information.
    #
    get '/info' do
      content_type 'application/json'
      {'name' => 'rgsyn',
       'version' => Rgsyn::VERSION,
       'os' => OS,
       'arch' => ARCH}.to_json
    end

    # Store a package (Gem, RPM, or SRPM).
    #
    put %r{/package/(#{Package::GEM}|#{Package::RPM})},
        :auth => User::ANY do |type|
      file = params[:data][:tempfile].path
      
      name_version = Library.name_version(type, file)
      if type == Package::RPM && Rpm2Gem::Rpm.source?(file)
        type = Package::SRPM
      end
      
      @library = find_library(name_version)
      
      if @library
        restrict!(User::REGULAR) if @library.owner != @user
      else
        @library = Library.create(:name_version => name_version,
                                  :owner => @user)
      end
                                 
      package = Package.create(:type => type,
                               :file => Helpers.cp_anonymous(file),
                               :generated => false,
                               :force => params[:force])
      @library.packages.push(package)
      
      content_type 'application/json'
      {:library_id => @library.id,
       :package_id => package.id,
       :name_version => @library.name_version}.to_json
    end
    
    # Request Gem->RPM conversion of a specified library.
    #
    put %r{/library/[^/]+/gem2rpm}, :auth => User::ANY do
      restrict!(User::REGULAR) if @library.owner != @user
      os = verify_os!(params[:os]) if params[:os]
      specfile = nil
      
      if params[:data]
        #user provided specfile
        error 403, 'Operating system must be specified!' if not os
        file = params[:data][:tempfile].path
        specfile = Specfile.new(File.read(file))
      else
        os ||= OS.first
        specfile = @library.generate_specfile(os)
      end
      
      if params[:deps] || params[:bdeps]
        specfile.add_dependencies(JSON.parse(params[:deps]),
                                  JSON.parse(params[:bdeps]))
      end
      
      specfile.license = params[:license] if params[:license]
      
      @library.log("Gem->RPM conversion requested. "\
                  "(#{os}, by: <b>#{@user.username}</b>)")
      @library.gem2rpm(os, specfile, :force => params[:force])
      
      200
    end
    
    # Request RPM->Gem conversion of a specified library.
    #
    put %r{/library/[^/]+/rpm2gem}, :auth => User::ANY do
      restrict!(User::REGULAR) if @library.owner != @user
      os = verify_os!(params[:os]) if params[:os]
    
      rpms = @library.packages.select {|p|
               [Package::RPM, Package::SRPM].include?(p.type)}
      error 403, 'Library has no RPM!' if rpms.empty?
      
      if os
        rpms = rpms.select { |package|
          os == package.lock { Rpm2Gem::Rpm.os(package.file) } }
        if rpms.empty?
          error 403, 'Library has no RPMs for the specified operating system!'
        end
      else
        os_set = Set.new
        rpms.each do |package|
          data = package.lock { Rpm2Gem::Rpm.new(package.file) }
          os_set.add(data.release[/\.(.+)$/, 1])
        end
        error 300, 'Operating system must be specified!' if os_set.size > 1
        os = os_set.first
      end
      
      if rpms.size == 1 && rpms.first.type == Package::SRPM
        @library.log("Build requested. "\
                     "(#{os}, #{ARCH.first}, by: <b>#{@user.username}</b>)")
        @library.async_rebuild_and_rpm2gem(rpms.first, :force => params[:force])
      else
        @library.log("RPM->Gem conversion requested. "\
                     "(#{os}, by: <b>#{@user.username}</b>)")
        @library.rpm2gem(os, :force => params[:force])
      end
      
      200
    end
    
    # Get all libraries present in the system.
    #
    get '/library' do
      content_type 'application/json'
      Library.all.map do |library|
        {'id' => library.id, 'name_version' => library.name_version}
      end.to_json
    end
    
    # Get a specified Mock log.
    #
    get %r{/library/[^/]+/log/(\d+)/([^/]+)} do |id, log|
      begin
        File.read("#{@library.logdir}/#{id}/#{log}")
      rescue Errno::ENOENT, Errno::EISDIR
        error 403, 'Such log does not exist!'
      end
    end
    
    # Get a list of logs a specified Mock operation of specified library.
    #
    get %r{/library/[^/]+/log/(\d+)} do |id|
      res = nil
      
      begin
        Dir.chdir("#{@library.logdir}/#{id}") do
          res = Dir.glob('**/*').select { |f| File.file?(f) }
        end
      rescue Errno::ENOENT, Errno::EISDIR
        error 403, 'Such directory does not exist!'
      end
      
      content_type 'application/json'
      res.to_json
    end
    
    # Get detailed log of specified library.
    #
    get %r{/library/[^/]+/log} do
      begin
        File.read("#{@library.logdir}/detailed.log")
      rescue Errno::ENOENT, Errno::EISDIR
        error 403, 'Such log does not exist!'
      end
    end
    
    # Get an RPM specfile generated from a gem of specified library.
    #
    get %r{/library/[^/]+/specfile} do
      os = params[:os] && verify_os!(params[:os])
      os ||= OS.first
      
      gem = @library.packages.detect { |package| package.type == Package::GEM }
      error 403, 'Library has no gem packages!' if gem.nil?
      file = gem.lock { Helpers.cp_anonymous(gem.file) }
      
      begin
        specfile = Specfile.generate(file, os)
      ensure
        FileUtils.rm_f(file)
      end
      
      if params[:deps] || params[:bdeps]
        specfile.add_dependencies(JSON.parse(params[:deps]),
                                  JSON.parse(params[:bdeps])) 
      end
      specfile.license = params[:license] if params[:license]
      specfile.content
    end
    
    # Get library information.
    #
    get %r{/library/[^/]+} do
      res = {'id' => @library.id,
             'name_version' => @library.name_version,
             'owner' => @library.owner.username,
             'created_on' => @library.created_on,
             'packages' => @library.packages.map do |package|
                            {'id' => package.id,
                             'name' => File.basename(package.file),
                             'generated' => package.generated}
                          end,
             'log' => ''}
      res['log'] = File.read("#{@library.logdir}/brief.log") rescue nil
      
      content_type 'application/json'
      res.to_json
    end

    # Delete library.
    #
    delete %r{/library/[^/]+}, :auth => User::ANY do
      @library.packages.each { |package| package.delete } #thread unsafe!
      @library.delete
      200
    end
    
    # Create a new user.
    #
    put '/user', :auth => User::REGULAR do
      rights = params[:rights] && User.parse_rights(params[:rights])
      rights ||= User::REGULAR

      if rights > @user.rights
        error 403, 'You cannot set user rights higher than yours!'
      end
      
      begin
        user = User.create(:username => params[:username],
                           :password => params[:password],
                           :rights => rights)
      rescue User::NameConflictError
        error 403, 'Such username already exists!'
      end
      200
    end
    
    # Get all users.
    #
    get '/user', :auth => User::REGULAR do
      content_type 'application/json'
      User.all.map do |user|
        {:id => user.id,
         :username => user.username,
         :rights => user.rights_s}
      end.to_json
    end

    # Change user's own data.
    #
    post '/user', :auth => User::ANY do
      @user.update(:password => params[:password])
      200
    end
    
    # Change specified user's data.
    #
    post %r{/user/(\d+)}, :auth => User::ADMIN do |uid|
      rights = params[:rights] && User.parse_rights(params[:rights])

      if rights && rights > @user.rights
        error 403, 'You cannot set user rights higher than yours!'
      end

      user = User[uid]
      user.update(:password => params[:password]) if params[:password]
      user.update(:rights => rights) if rights
      200
    end
    
    # Delete specified user.
    #
    delete %r{/user/(\d+)}, :auth => User::ADMIN do |uid|
      User[uid].delete
      200
    end
    
    error JSON::ParserError do
      [400, 'Parameters received were corrupted!']
    end
    
    error Repository::NameConflictError do
      [403, 'Such package is already present!']
    end

    error Package::InvalidFileError do
      [403, 'Received file is either corrupted or in bad format!']
    end
    
    error do
      Logging.logger[self].error(env['sinatra.error'])
      500
    end
    
    helpers do
      def restrict!(level)
        error 401, 'Insufficent rights!' if @user.rights.to_i < level.to_i
      end
      
      def find_library(ident)
        if !!(ident =~ /^[0-9]+$/)
          Library[ident]
        else
          libraries = Library.all.select do |l|
            l.name_version.start_with?(ident)
          end
          if libraries.size > 1
            content_type 'application/json'
            error 300, libraries.map { |l| l.name_version }.to_json
          end
          libraries.first
        end
      end
      
      def verify_os!(os)
        unless OS.include?(os)
          error 403, "Operating system #{os} is not supported!"
        end
        os
      end
    end

  end

end
