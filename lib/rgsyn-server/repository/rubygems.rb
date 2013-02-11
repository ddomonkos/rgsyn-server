require 'rgsyn-server/repository/repo_mixin'
require 'logging'
require 'rubygems/user_interaction'
require 'rubygems/indexer'
require 'fileutils'
require 'drb'

module Rgsyn

  module Repository

    class RubyGems
      include RepoMixin

      def initialize(repo_uri, dir)
        super(dir)
        @indexer = Gem::Indexer.new(@dir)
        DRb.start_service(repo_uri, self)
      end
      
      # Schedule addition of a file into the repository. Returns the ID of a
      # created package.
      #
      def schedule_add(package_id, force = false)
        package = Package[package_id]
      
        begin
          gemformat = package.lock {Gem::Format.from_file_by_path(package.file)}
        rescue Gem::Package::FormatError
          raise 'Invalid format of the gem package!'
        end
        raise 'Invalid format of the gem package!' if gemformat.nil?
        
        super(package, "#{@dir}/gems/#{gemformat.spec.file_name}", force)
      end
      
      # Actually add and delete packages, that were scheduled for addition and
      # deletion and update repository indices.
      #
      def refresh
        super do |modified|
          return unless modified
          @indexer.generate_index  #TODO: update_index?
        end
      end
      
    end
    
  end

end
