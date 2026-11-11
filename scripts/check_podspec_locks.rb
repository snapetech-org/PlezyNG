#!/usr/bin/env ruby
# Check local podspec metadata before compiling native frameworks. CocoaPods
# hashes homepage and other metadata as well as dependency declarations.
require 'cocoapods-core'
require 'digest'
require 'pathname'

root = Pathname.new(__dir__).parent
update = ARGV.delete('--update')
abort 'Usage: ruby scripts/check_podspec_locks.rb [--update]' unless ARGV.empty?

specs = {
  'ios' => [
    'packages/plezy_preparation/ios/plezy_preparation.podspec',
    'native/games/romm/apple/plezy_romm_ios.podspec',
    'native/games/romm/apple/plezy_romm_worker.podspec',
    'packages/plezy_torrent/ios/plezy_torrent.podspec',
  ],
  'macos' => [
    'native/games/romm/apple/plezy_romm_macos.podspec',
    'packages/plezy_torrent/macos/plezy_torrent.podspec',
  ],
  'tvos' => [
    'native/games/romm/apple/plezy_romm_tvos.podspec',
    'packages/plezy_torrent/ios/plezy_torrent_tvos.podspec',
  ],
}

errors = []
specs.each do |platform, paths|
  lock_path = root.join(platform, 'Podfile.lock')
  lock = Pod::Lockfile.from_file(lock_path)
  checksums = lock.to_hash.fetch('SPEC CHECKSUMS')
  source = lock_path.read
  paths.each do |path|
    spec = Pod::Specification.from_file(root.join(path))
    actual = checksums.fetch(spec.name)
    # CocoaPods copies local Ruby specs to sandbox JSON before generating the
    # lockfile, so hash that canonical serialization, not the Ruby source file.
    expected = Digest::SHA1.hexdigest(spec.to_pretty_json)
    next if actual == expected

    if update
      line = "  #{spec.name}: #{actual}"
      abort "Ambiguous checksum in #{lock_path}: #{spec.name}" unless source.lines.count { |value| value.chomp == line } == 1
      source = source.sub(line, "  #{spec.name}: #{expected}")
      puts "#{platform}: updated #{spec.name} metadata checksum"
    else
      errors << "#{platform}/Podfile.lock: #{spec.name} metadata changed (#{actual} -> #{expected})"
    end
  end
  lock_path.write(source) if update && source != lock_path.read
end

# Trunk may edit metadata for an existing version (for example deprecation).
# Keep the reviewed official document immutable instead of trusting a CDN edge.
gtm_spec = 'https://raw.githubusercontent.com/CocoaPods/Specs/fd8ca834492e570dddaffabba6a5a1c12b5e92c3/Specs/2/c/c/GTMAppAuth/5.0.0/GTMAppAuth.podspec.json'
%w[ios macos].each do |platform|
  podfile = root.join(platform, 'Podfile').read
  lock = Pod::Lockfile.from_file(root.join(platform, 'Podfile.lock')).to_hash
  declaration = "pod 'GTMAppAuth', :podspec => '#{gtm_spec}'"
  pinned = podfile.lines.count { |line| line.strip == declaration } == 1 &&
    lock.fetch('DEPENDENCIES').count("GTMAppAuth (from `#{gtm_spec}`)") == 1 &&
    lock.fetch('EXTERNAL SOURCES').fetch('GTMAppAuth', {}) == { podspec: gtm_spec } &&
    lock.fetch('SPEC REPOS').values.none? { |names| names.include?('GTMAppAuth') } &&
    lock.fetch('SPEC CHECKSUMS').fetch('GTMAppAuth') == '9566e1a3451fd6967b58188fa15286fb6ae7914f' &&
    lock.fetch('PODS').any? { |item| item.is_a?(Hash) && item.key?('GTMAppAuth (5.0.0)') } &&
    lock.fetch('PODFILE CHECKSUM') == Digest::SHA1.hexdigest(podfile)
  errors << "#{platform}: GTMAppAuth must retain its immutable official podspec and matching lockfile" unless pinned
end

unless errors.empty?
  abort "#{errors.join("\n")}\nRun ruby scripts/check_podspec_locks.rb --update with the pinned CocoaPods version."
end
puts "Local podspec checksums match all three Apple lockfiles (CocoaPods core #{Gem.loaded_specs.fetch('cocoapods-core').version})."
