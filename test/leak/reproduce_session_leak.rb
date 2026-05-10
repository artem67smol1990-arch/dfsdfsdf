#!/usr/bin/env ruby
# frozen_string_literal: true

# Reproduces the unbounded memory leak in WebConsole::Session.inmemory_storage.
#
# Each dev-mode exception captured by web-console creates a Session that
# retains stack-frame Binding objects. Bindings hold the full lexical scope,
# which in a Rails app pins `Rails.application.routes` -> the entire
# Journey route tree. Because the storage Hash has no eviction, every
# captured exception leaks a fresh RouteSet generation.
#
# The script simulates this without booting Rails: it builds a synthetic
# "route tree" payload, then captures a Binding that closes over it inside
# many short-lived contexts. The growth of `Session.inmemory_storage.size`
# and process RSS demonstrates the leak directly.
#
# Usage:
#   bundle exec ruby test/leak/reproduce_session_leak.rb
#   N_ERRORS=200 bundle exec ruby test/leak/reproduce_session_leak.rb
#   MAX_SESSIONS=10 bundle exec ruby test/leak/reproduce_session_leak.rb
#
# Set MAX_SESSIONS=nil to opt back into the legacy unbounded behaviour.

require "objspace"

# Run from the gem root so we exercise THIS checkout, not an installed copy.
$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "active_support"
require "active_support/core_ext/class/attribute_accessors"
require "web_console/exception_mapper"
require "web_console/evaluator"
require "web_console/context"
require "web_console/session"

# Per-iteration "RouteSet stand-in": a deeply-nested object graph sized to
# resemble what a real Rails::Engine::LazyRouteSet retains. Each FakeRouteSet
# instance allocates ~5 MB of heap so the leak is unmistakable in `ps`.
class FakeRouteSet
  ROUTE_PAYLOAD_SIZE = 50_000

  def initialize(generation)
    @generation = generation
    @routes = Array.new(ROUTE_PAYLOAD_SIZE) { |i| { gen: generation, id: i, path: "/r/#{generation}/#{i}" } }
  end
end

def rss_mb
  File.read("/proc/self/status")[/VmRSS:\s+(\d+)/, 1].to_i / 1024
rescue Errno::ENOENT
  -1 # non-Linux; skip
end

def emit(label, sessions, count, rss)
  puts format("%-22s sessions=%-4d errors_seen=%-4d rss=%4d MB live_objects=%d",
              label, sessions, count, rss, ObjectSpace.count_objects[:TOTAL])
end

# Apply config from environment.
case ENV["MAX_SESSIONS"]
when nil       then # use the default declared in Session
when "nil", "" then WebConsole::Session.max_sessions = nil
else                WebConsole::Session.max_sessions = Integer(ENV["MAX_SESSIONS"])
end

n_errors = Integer(ENV.fetch("N_ERRORS", 200))

puts "WebConsole::Session.max_sessions = #{WebConsole::Session.max_sessions.inspect}"
puts "Simulating #{n_errors} captured dev-mode exceptions..."
puts

WebConsole::Session.inmemory_storage.clear
GC.start
emit("baseline", WebConsole::Session.inmemory_storage.size, 0, rss_mb)

n_errors.times do |i|
  # Each iteration creates a fresh "route tree" and captures a Binding that
  # closes over it from inside a method frame -- exactly the shape of a real
  # exception traceback through a Rails controller action.
  route_set = FakeRouteSet.new(i)
  capture = ->(binding_to_save) { WebConsole::Session.new([[binding_to_save]]) }

  # Force the closure to actually reference route_set by reading it inside the
  # block. Otherwise the Ruby compiler can elide the capture.
  _ = route_set
  capture.call(binding)

  if (i + 1) % (n_errors / 10).clamp(1, 1_000_000) == 0
    GC.start
    emit("after #{i + 1}", WebConsole::Session.inmemory_storage.size, i + 1, rss_mb)
  end
end

GC.start
puts
emit("final", WebConsole::Session.inmemory_storage.size, n_errors, rss_mb)
puts
puts "If max_sessions is bounded, `sessions` should plateau at the limit and"
puts "RSS should stay flat. With max_sessions = nil, `sessions` keeps growing"
puts "and RSS climbs roughly linearly with N_ERRORS."
