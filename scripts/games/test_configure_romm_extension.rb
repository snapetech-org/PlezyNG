#!/usr/bin/env ruby
# SPDX-License-Identifier: AGPL-3.0-only
require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'rbconfig'
require 'xcodeproj'

class RommExtensionConfigurationTest < Minitest::Test
  def test_production_worker_links_cpp_in_every_configuration_without_losing_flags
    Dir.mktmpdir('pleazyng-romm-config-') do |root|
      script_dir = File.join(root, 'scripts/games')
      FileUtils.mkdir_p([script_dir, File.join(root, 'ios/Flutter')])
      script = File.join(script_dir, 'configure_romm_extension.rb')
      FileUtils.cp(File.join(__dir__, 'configure_romm_extension.rb'), script)
      project_path = File.join(root, 'ios/Runner.xcodeproj')
      project = Xcodeproj::Project.new(project_path)
      host = project.new_target(:application, 'Runner', :ios, '15.5')
      host.add_build_configuration('Profile', :release)
      worker = project.new_target(:app_extension, 'RommWorker', :ios, '26.0')
      worker.build_configurations.each do |config|
        config.build_settings['OTHER_LDFLAGS'] = '-Wl,-dead_strip'
      end
      project.save

      assert system(RbConfig.ruby, script, project_path)
      first = File.binread(File.join(project_path, 'project.pbxproj'))
      assert system(RbConfig.ruby, script, project_path)
      assert_equal first, File.binread(File.join(project_path, 'project.pbxproj'))
      worker = Xcodeproj::Project.open(project_path).targets.find { |target| target.name == 'RommWorker' }
      assert_equal %w[Debug Profile Release], worker.build_configurations.map(&:name).sort
      worker.build_configurations.each do |config|
        flags = config.build_settings['OTHER_LDFLAGS']
        assert_equal 1, flags.count('-lc++'), config.name
        assert_includes flags, '$(inherited)', config.name
        assert_includes flags, '-Wl,-dead_strip', config.name unless config.name == 'Profile'
      end
    end
  end
end
