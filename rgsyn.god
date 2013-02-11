require 'rgsyn-server/environment'
require 'fileutils'

DIR = File.dirname(File.expand_path(__FILE__))

#initalize dir structure
FileUtils.mkdir_p("#{DIR}/log/workers")
FileUtils.mkdir_p("#{DIR}/public/gem/gems")
FileUtils.mkdir_p("#{DIR}/public/yum")

#Server
God.watch do |w|
  w.name = "rgsyn-server"
  w.dir = DIR
  w.start = "rackup config/rack.ru"
  w.log = "#{DIR}/log/server.log"
  w.interval = 5.seconds
  w.stop_timeout = 1.seconds #debug only
  w.keepalive
end

#Workers
NUM_WORKERS.times do |i|
  God.watch do |w|
    w.name = "rgsyn-worker-#{i}"
    w.interval = 15.seconds
    w.env = {'QUEUE' => 'mock_build',
             'VERBOSE' => 'true'}
    w.dir = DIR
    w.start = "rake -f config/Rakefile resque:work"
    w.log = "#{DIR}/log/workers/#{i}.log"
    w.stop_timeout = 1.seconds #debug only
    w.keepalive
  end
end
