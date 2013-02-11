require 'rgsyn-server/repository/repo_mixin'
require 'rgsyn-server/helpers'
require 'logging'
require 'rpm2gem/rpm'
require 'fileutils'
require 'drb'

module Rgsyn

  module Repository

    class Yum
      include RepoMixin
      
      def initialize(repo_uri, dir)
        super(dir)
        DRb.start_service(repo_uri, self)
      end
      
      # Schedule addition of a file into the repository. Returns the ID of a
      # created package.
      #
      def schedule_add(package_id, force = false)
        package = Package[package_id]
        data = package.lock { data = Rpm2Gem::Rpm.new(package.file) }
        subext = if data.source? then 'src' else data.arch end
        subdir = if data.source? then 'SRPMS' else data.arch end
        super(package, "#{@dir}/#{subdir}/#{data.name}-#{data.version}-"\
                       "#{data.release}.#{subext}.rpm", force)
      end
      
      # Actually add and remove packages, that were scheduled for addition and
      # removal and update repository indices.
      #
      def refresh
        super do |modified|
          return unless modified
          `createrepo -d #{@dir}` #TODO: --update switch?
        end
      end
      
    end
    
  end
   
end
