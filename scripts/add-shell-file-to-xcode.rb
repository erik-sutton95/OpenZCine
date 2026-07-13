#!/usr/bin/env ruby
# frozen_string_literal: true

# Register an ios/Runner/*.swift shell file into the Runner Xcode target (the project lists shell
# sources individually). Adds the file to the same group as an existing shell file and the target's
# Sources build phase. Idempotent.
#
# Usage: ruby scripts/add-shell-file-to-xcode.rb RedDownloadView.swift [More.swift ...]

require 'xcodeproj'

PROJECT_PATH = File.expand_path('../ios/Runner.xcodeproj', __dir__)
TARGET_NAME = 'Runner'
ANCHOR = 'NativeAppRoot.swift' # an existing shell file whose group we reuse

abort 'usage: add-shell-file-to-xcode.rb <File.swift> [...]' if ARGV.empty?

project = Xcodeproj::Project.open(PROJECT_PATH)
target = project.targets.find { |t| t.name == TARGET_NAME }
abort "target #{TARGET_NAME.inspect} not found" unless target

anchor = project.files.find { |f| f.display_name == ANCHOR }
abort "anchor #{ANCHOR.inspect} not found" unless anchor
group = anchor.parent

changed = false
ARGV.each do |basename|
  if group.files.any? { |f| f.display_name == basename }
    puts "skip (already referenced): #{basename}"
    next
  end
  ref = group.new_reference(basename)
  ref.name = basename
  ref.path = basename
  ref.source_tree = '<group>'
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
