#!/usr/bin/env ruby
# SPDX-License-Identifier: AGPL-3.0-only
# Connect the bundled iOS worker to the existing Xcode/CocoaPods project.
require 'xcodeproj'
require 'pathname'
require 'shellwords'

root = File.expand_path('../..', __dir__)
project_path = ARGV[0] || File.join(root, 'ios/Runner.xcodeproj')
project = Xcodeproj::Project.open(project_path)
host = project.targets.find { |target| target.name == 'Runner' }
raise 'Runner target missing' unless host
worker = project.targets.find { |target| target.name == 'RommWorker' }
worker ||= project.new_target(:app_extension, 'RommWorker', :ios, '26.0')
worker.product_type = 'com.apple.product-type.extensionkit-extension'
group = project.main_group.find_subpath('RommWorker', true)
base = Pathname.new(File.dirname(project_path))
def source(group, target, absolute, base)
  relative = Pathname.new(absolute).relative_path_from(base).to_s
  reference = group.files.find { |file| file.path == relative } || group.new_file(relative)
  target.source_build_phase.add_file_reference(reference, true)
end
extension_root = File.join(root, 'native/games/romm/apple/extension')
source(group, worker, File.join(extension_root, 'RommWorkerExtension.swift'), base)
source(group, host, File.join(extension_root, 'HostBroker.swift'), base)
host.add_dependency(worker) unless host.dependencies.any? { |dependency| dependency.target == worker }
phase = host.copy_files_build_phases.find { |value| value.name == 'Embed Romm Extension' }
phase ||= host.new_copy_files_build_phase('Embed Romm Extension')
phase.dst_subfolder_spec = '16'
phase.dst_path = '$(EXTENSIONS_FOLDER_PATH)'
build_file = phase.files.find { |value| value.file_ref == worker.product_reference }
build_file ||= phase.add_file_reference(worker.product_reference, true)
build_file.settings = { 'ATTRIBUTES' => ['CodeSignOnCopy', 'RemoveHeadersOnCopy'] }
# Processing the host Info.plist depends on the embedded extension. Flutter's
# Thin Binary script consumes that plist; appending the copy after this script
# or the CocoaPods embedding phases therefore creates a dependency cycle.
host.build_phases.delete(phase)
postprocess = host.build_phases.index do |value|
  ['Thin Binary', '[CP] Embed Pods Frameworks', '[CP] Copy Pods Resources'].include?(value.display_name)
end
host.build_phases.insert(postprocess || host.build_phases.length, phase)

host.build_configurations.each do |config|
  unless worker.build_configurations.any? { |value| value.name == config.name }
    worker.add_build_configuration(config.name, config.type)
  end
  config.build_settings['EX_ENABLE_EXTENSION_POINT_GENERATION'] = 'YES'
end
worker.build_configurations.each do |config|
  # The Swift extension links the static C++ worker. Its host's linker flags
  # do not propagate to this separate target.
  flags = config.build_settings['OTHER_LDFLAGS']
  flags = flags.is_a?(String) ? Shellwords.split(flags) : Array(flags).dup
  flags.unshift('$(inherited)') unless flags.include?('$(inherited)')
  flags << '-lc++' unless flags.include?('-lc++')
  config.build_settings['OTHER_LDFLAGS'] = flags
  host_config = host.build_configurations.find { |value| value.name == config.name }
  entitlements = Pathname.new(File.join(extension_root, 'RommWorker.entitlements')).relative_path_from(base).to_s
  config.build_settings.merge!({
    'PRODUCT_BUNDLE_IDENTIFIER' => 'org.snapetech.pleazyng.RommWorker',
    'PRODUCT_NAME' => '$(TARGET_NAME)',
    'SWIFT_VERSION' => '5.0',
    'IPHONEOS_DEPLOYMENT_TARGET' => '26.0',
    'TARGETED_DEVICE_FAMILY' => '1,2',
    'SUPPORTED_PLATFORMS' => 'iphoneos iphonesimulator',
    'GENERATE_INFOPLIST_FILE' => 'YES',
    'INFOPLIST_KEY_CFBundleDisplayName' => 'Pleazyng Game Worker',
    'MARKETING_VERSION' => '$(FLUTTER_BUILD_NAME)',
    'CURRENT_PROJECT_VERSION' => '$(FLUTTER_BUILD_NUMBER)',
    'APPLICATION_EXTENSION_API_ONLY' => 'YES',
    'ENABLE_ENHANCED_SECURITY' => 'YES',
    'EX_ENABLE_EXTENSION_POINT_GENERATION' => 'YES',
    'CODE_SIGN_ENTITLEMENTS' => entitlements,
    'SKIP_INSTALL' => 'YES',
    'LD_RUNPATH_SEARCH_PATHS' => ['$(inherited)', '@executable_path/Frameworks'],
  })
  config.build_settings.delete('INFOPLIST_FILE')
  %w[DEVELOPMENT_TEAM CODE_SIGN_STYLE].each do |setting|
    value = host_config&.build_settings&.[](setting)
    config.build_settings[setting] = value if value
  end
  filename = "RommWorker.#{config.name.downcase}.xcconfig"
  directory = File.join(root, 'ios/Flutter')
  File.write(File.join(directory, filename),
    "#include \"Generated.xcconfig\"\n" \
    "#include? \"../Pods/Target Support Files/Pods-RommWorker/Pods-RommWorker.#{config.name.downcase}.xcconfig\"\n")
  relative = Pathname.new(File.join(directory, filename)).relative_path_from(base).to_s
  reference = group.files.find { |file| file.path == relative } || group.new_file(relative)
  config.base_configuration_reference = reference
end
project.save
puts 'Configured the bundled iOS Enhanced Security game extension.'
