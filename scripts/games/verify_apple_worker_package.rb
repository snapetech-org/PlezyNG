#!/usr/bin/env ruby
# SPDX-License-Identifier: AGPL-3.0-only
require 'xcodeproj'
require 'fileutils'
require 'json'

root = File.expand_path('../..', __dir__)
scratch = File.join(root, 'build/romm-extension-package')
FileUtils.mkdir_p(scratch)
project_path = File.join(scratch, 'Runner.xcodeproj')
FileUtils.cp_r(File.join(root, 'ios/Runner.xcodeproj'), project_path) unless File.exist?(project_path)
configure = File.join(root, 'scripts/games/configure_romm_extension.rb')
raise 'Initial extension setup failed' unless system('ruby', configure, project_path)
first = File.read(File.join(project_path, 'project.pbxproj'))
raise 'Repeated extension setup failed' unless system('ruby', configure, project_path)
raise 'Extension configuration is not idempotent' unless first == File.read(File.join(project_path, 'project.pbxproj'))
project = Xcodeproj::Project.open(project_path)
host = project.targets.find { |target| target.name == 'Runner' }
worker = project.targets.find { |target| target.name == 'RommWorker' }
raise 'Expected exactly one worker' unless project.targets.count { |target| target.name == 'RommWorker' } == 1
raise 'Wrong extension product' unless worker.product_type == 'com.apple.product-type.extensionkit-extension'
raise 'Missing host dependency' unless host.dependencies.count { |value| value.target == worker } == 1
phase = host.copy_files_build_phases.find { |value| value.name == 'Embed Romm Extension' }
raise 'Wrong extension packaging destination' unless phase && phase.dst_subfolder_spec == '16' &&
  phase.dst_path == '$(EXTENSIONS_FOLDER_PATH)' && phase.files.size == 1
raise 'Missing profile build' unless worker.build_configurations.map(&:name).include?('Profile')

# Link the production worker into its real extension target. The verification
# project omits app-only Pods and uses the already-built simulator framework.
native = File.join(root, 'build/romm-extension-compile/Release-iphonesimulator')
framework = File.join(native, 'PlezyRetroWorker.framework')
raise 'Native worker framework missing' unless File.file?(File.join(framework, 'PlezyRetroWorker'))
# Xcode resolves every project package even when only this extension is built.
# The copied host's generated Flutter package is absent here and its relative
# DV package path changes. Strip app-only package references in this disposable
# verification project; the production project and worker dependencies stay intact.
project.targets.each do |target|
  target.frameworks_build_phase.files.to_a.each do |build_file|
    build_file.remove_from_project if build_file.product_ref
  end
  target.package_product_dependencies.clear
end
project.root_object.package_references.clear
reference = project.frameworks_group.new_file(framework)
worker.frameworks_build_phase.add_file_reference(reference, true)
worker.build_configurations.each do |config|
  config.base_configuration_reference = nil
  config.build_settings['FRAMEWORK_SEARCH_PATHS'] = [native]
  config.build_settings['OTHER_LDFLAGS'] = ['$(inherited)', '-lc++']
  config.build_settings['CODE_SIGNING_ALLOWED'] = 'NO'
  config.build_settings['FLUTTER_BUILD_NAME'] = '1.0'
  config.build_settings['FLUTTER_BUILD_NUMBER'] = '1'
end
project.save
raise 'Extension link failed' unless system(
  'xcodebuild', '-project', project_path, '-target', 'RommWorker',
  '-configuration', 'Release', '-sdk', 'iphonesimulator',
  'ARCHS=x86_64', 'ONLY_ACTIVE_ARCH=YES', 'CODE_SIGNING_ALLOWED=NO',
  "SYMROOT=#{scratch}/products", "OBJROOT=#{scratch}/objects")
packages = Dir.glob(File.join(scratch, 'products/Release-iphonesimulator/*.appex'))
raise 'Expected a built extension package' unless packages.size == 1
# Xcode writes a binary plist. xcodeproj's conflict-marker text scan does not
# accept its arbitrary bytes; ask the platform plist tool to decode it first.
info = JSON.parse(IO.popen(['plutil', '-convert', 'json', '-o', '-', File.join(packages.first, 'Info.plist')], &:read))
raise 'Could not decode extension metadata' unless $?.success?
raise 'Wrong worker identity' unless info['CFBundleIdentifier'] == 'org.snapetech.pleazyng.RommWorker'
raise 'Worker deployment boundary changed' unless info['MinimumOSVersion'].to_f >= 26
puts "ROMM_EXTENSION_INFO #{info.inspect}"
puts 'Production iOS extension linked; Xcode target, embedding and repeated configuration verified.'
