require 'rgsyn-server/helpers'
require 'rgsyn-server/entity/package'
require 'drb/drb'
require 'monitor'

module Rgsyn
  
  module Repository
  
    class NameConflictError < StandardError; end

    module RepoMixin
      include DRb::DRbUndumped
      attr_reader :dir
    
      def initialize(dir)
        @dir = dir
        @monitor = Monitor.new
        @queues_mutex = Mutex.new
        @add_queue = []
        @delete_queue = []
      end
      
      # Abstract pre-implementation. Classes including this module should
      # determine and provide dest_path by themselves.
      #
      def schedule_add(package, dest_path, force = false)
        @queues_mutex.synchronize do
          conflict = @add_queue.detect { |x| x[1] == dest_path }
          @add_queue.delete(conflict) if conflict && force
          conflict &&= conflict[0]
          
          conflict ||= Package.with(:file, dest_path)
          
          if conflict
            raise NameConflictError, File.basename(dest_path) if not force
            conflict.lock do
              name_version = Library.name_version(conflict.type, conflict.file)
              library = Library.with(:name_version, name_version)
              library.packages.delete(conflict)
              _file = conflict.file
              conflict.delete!
              FileUtils.rm_f(_file)
            end
          end
          
          @add_queue.push([package, dest_path])
        end
      end
      
      # Schedule a package (as a file) deletion from the repository.
      #
      def schedule_delete(file)
        @queues_mutex.synchronize { @delete_queue.push(file) }
      end
      
      # Abstract pre-implementation. Classes including the module should provide
      # a block that actually updates repository indices.
      #
      def refresh
        add_queue = nil
        delete_queue = nil
        
        @queues_mutex.synchronize do
          add_queue = Array.new(@add_queue)
          delete_queue = Array.new(@delete_queue)
          @add_queue.clear
          @delete_queue.clear
        end
        
        @monitor.synchronize do
          modified = ! add_queue.empty? || ! delete_queue.empty?
          delete_queue.each { |file| FileUtils.rm_f(file) }
          
          add_queue.each do |package, dest_path|
            package.lock do
              FileUtils.mkdir_p(File.dirname(dest_path))
              FileUtils.mv(package.file, dest_path, :force => true)
              package.update(:file => dest_path)
            end
          end
          yield(modified)
        end
      end
      
    end
    
  end
  
end
