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

unless errors.empty?
  abort "#{errors.join("\n")}\nRun ruby scripts/check_podspec_locks.rb --update with the pinned CocoaPods version."
end
puts "Local podspec checksums match all three Apple lockfiles (CocoaPods core #{Gem.loaded_specs.fetch('cocoapods-core').version})."
