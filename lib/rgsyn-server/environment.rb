require 'yaml'

config_file = File.expand_path('../../config/rgsyn-server.yml',
                               File.dirname(__FILE__))

unless File.exists?(config_file)
  $stderr.puts 'Error: No configuration file found! See README for more info.'
  exit 1
end

config = YAML::load_file(config_file)

inital_port = config['drb_initial_port'].to_i

OS = config['operating_systems']
ARCH = config['architectures']
NUM_WORKERS = config['num_workers'].to_i

GEM_URI = "druby://localhost:#{inital_port}"
YUM_URI = {}
OS.each { |os| YUM_URI[os] = "druby://localhost:#{inital_port+=1}" }
