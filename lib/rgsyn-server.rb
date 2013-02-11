require 'rgsyn-server/environment'
require 'rgsyn-server/entity/user'
require 'rgsyn-server/repository/rubygems'
require 'rgsyn-server/repository/yum'
require 'logging'
require 'ohm'

module Rgsyn

  VERSION = '0.1.0'

  # Initialize Rgsyn - set up log appender, create implicit admin if running
  # for the first time and create maintainer threads for repositories.
  # 
  def self.init
    Logging.logger.root.appenders = Logging.appenders.stdout
    
    Ohm.connect(:url => 'redis://localhost:6379', :thread_safe => true) #TODO: thread safety
  
    if User.all.empty?
      admin = User.create(:username => 'admin',
                          :password => 'admin',
                          :rights => User::ADMIN)
    end
    
    #periodically maintain RubyGems repository
    dir = File.expand_path("../public/gem",
                           File.dirname(__FILE__))
    repo = Repository::RubyGems.new(GEM_URI, dir)
    Thread.new do
      loop { repo.refresh rescue $stderr.puts $!.inspect; sleep 3 }
    end
    
    #periodically maintain YUM repositories
    YUM_URI.each do |os, uri|
      _dir = File.expand_path("../public/yum/#{os}",
                              File.dirname(__FILE__))
      _repo = Repository::Yum.new(uri, _dir)
      Thread.new do
        loop { _repo.refresh rescue $stderr.puts $!.inspect; sleep 3 }
      end
    end
  end

end
