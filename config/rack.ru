#!/usr/bin/env ruby

require 'rubygems' if RUBY_VERSION < '1.9'
require 'rgsyn-server'
require 'rgsyn-server/server'
require 'resque'
require 'resque/server'
require 'redis'

use Rack::ShowExceptions

Rgsyn.init

run Rack::URLMap.new \
  "/"       => Rgsyn::Server.new,
  "/resque" => Resque::Server.new
