#!/usr/bin/env ruby
# frozen_string_literal: true

# Adds a remote Swift Package dependency to the iOS Runner target.
# Usage: ruby scripts/add-spm-dependency.rb <repo-url> <product> <min-version>
# Idempotent: skips if the product dependency already exists.

require 'xcodeproj'

PROJECT_PATH = File.expand_path('../ios/Runner.xcodeproj', __dir__)
TARGET_NAME = 'Runner'

repo_url, product, min_version = ARGV
abort 'usage: add-spm-dependency.rb <repo-url> <product> <min-version>' unless repo_url && product && min_version

project = Xcodeproj::Project.open(PROJECT_PATH)
target = project.targets.find { |t| t.name == TARGET_NAME }
abort "target #{TARGET_NAME.inspect} not found" unless target

if target.package_product_dependencies.any? { |d| d.product_name == product }
  puts "skip (already present): #{product}"
  exit 0
end

pkg = project.new(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
pkg.repositoryURL = repo_url
pkg.requirement = { 'kind' => 'upToNextMajorVersion', 'minimumVersion' => min_version }
project.root_object.package_references << pkg

dep = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
dep.package = pkg
dep.product_name = product
target.package_product_dependencies << dep

build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
build_file.product_ref = dep
target.frameworks_build_phase.files << build_file

project.save
puts "added #{product} (#{repo_url}, >= #{min_version})"
