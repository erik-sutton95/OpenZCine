#!/usr/bin/env ruby
# frozen_string_literal: true

# Register a Sources/OpenZCineCore/*.swift file into the iOS Runner Xcode target.
#
# The iOS app compiles the portable core sources directly (it does not link
# OpenZCineCore as a module — see ios/Runner.xcodeproj), so every new core file
# must be added to the OpenZCineCore group and the Runner "Sources" build phase.
# SPM globs the directory automatically; only Xcode needs this registration.
#
# Usage: ruby scripts/add-core-file-to-xcode.rb AssistToolActivation.swift [More.swift ...]
# Idempotent: skips files already referenced.

require 'xcodeproj'

PROJECT_PATH = File.expand_path('../ios/Runner.xcodeproj', __dir__)
GROUP_NAME = 'OpenZCineCore'
TARGET_NAME = 'Runner'

abort 'usage: add-core-file-to-xcode.rb <File.swift> [...]' if ARGV.empty?

project = Xcodeproj::Project.open(PROJECT_PATH)

group = project.main_group.recursive_children.find do |child|
  child.isa == 'PBXGroup' && child.display_name == GROUP_NAME
end
abort "group #{GROUP_NAME.inspect} not found" unless group

target = project.targets.find { |t| t.name == TARGET_NAME }
abort "target #{TARGET_NAME.inspect} not found" unless target

changed = false
ARGV.each do |basename|
  rel = "../Sources/OpenZCineCore/#{basename}"
  if group.files.any? { |f| f.path == rel }
    puts "skip (already referenced): #{basename}"
    next
  end

  ref = group.new_reference(rel)
  ref.name = basename
  ref.path = rel
  ref.source_tree = 'SOURCE_ROOT'
  ref.last_known_file_type = 'sourcecode.swift'
  target.add_file_references([ref])
  changed = true
  puts "added: #{basename}"
end

if changed
  project.save
  puts "saved #{PROJECT_PATH}"
else
  puts 'no changes'
end
