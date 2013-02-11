require 'ohm'
require 'rgsyn-server/environment'
require 'drb/drb'
require 'rpm2gem/rpm'

module Rgsyn

  # Abstracts from files - necessary due to parallelism, and useful as we can
  # remember some extra stuff (like the type, whether the package was
  # received or generated, or the list of other packages that were created from
  # this package).
  #
  class Package < Ohm::Model
  
    class InvalidFileError < StandardError; end
  
    GEM = 'gem'
    RPM = 'rpm'
    SRPM = 'srpm'

    attribute :type
    attribute :file
    attribute :generated
    list :children, Package
    
    unique :file
    
    def self.create(p)
      force = p.delete(:force) || false
      package = super(p)
      
      begin
        #place the package into repository
        if package.type == GEM
          DRbObject.new_with_uri(GEM_URI).schedule_add(package.id, force)
        else
          os = Rpm2Gem::Rpm.os(package.file) #this no-lock is an exception!
          DRbObject.new_with_uri(YUM_URI[os]).schedule_add(package.id, force)
        end
      rescue => ex
        FileUtils.rm_f(package.file)
        package.delete!
        raise ex
      end
      
      package
    end
    
    # All code manipulating either the _file_ attribute (writing) or the file
    # behind it itself (reading AND writing) must be done inside the block
    # provided by this method! (concurrency) This grants exclusive access,
    # therefore it should not held too long.
    #
    # The method also refreshes all attributes once the lock has been acquired!
    #
    def lock
      33.times do
        break if Ohm.redis.setnx("#{key}:lock", '1')
        sleep 0.3
      end
      
      begin
        load! #refresh file attribute
        res = yield
      ensure
        Ohm.redis.del("#{key}:lock")
      end
      res
    end
    
    alias_method :'delete!', :delete
    
    def delete
      lock do
        _type = type
        _file = file
        delete!
        if type == GEM
          DRbObject.new_with_uri(GEM_URI).schedule_delete(file)
        else
          os = Rpm2Gem::Rpm.os(file)
          DRbObject.new_with_uri(YUM_URI[os]).schedule_delete(file)
        end
      end
    end
    
  end
  
end
