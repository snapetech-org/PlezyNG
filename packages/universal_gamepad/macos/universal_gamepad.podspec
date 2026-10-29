Pod::Spec.new do |s|
  s.name             = 'universal_gamepad'
  s.version          = '1.5.8'
  s.summary          = 'macOS implementation for the gamepad Flutter plugin.'
  s.description      = <<-DESC
  Cross-platform Flutter plugin providing unified gamepad input using the
  GameController framework on macOS.
                       DESC
  s.homepage         = 'https://github.com/edde746/universal_gamepad'
  s.license          = { :type => 'MIT', :file => '../LICENSE' }
  s.author           = { 'gamepad' => 'dev@gamepads-plus.dev' }
  s.source           = { :http => 'https://github.com/edde746/universal_gamepad' }

  s.platform         = :osx, '11.0'
  s.osx.deployment_target = '11.0'

  s.source_files     = 'Classes/**/*'
  s.dependency 'FlutterMacOS'

  s.framework        = 'GameController'

  s.swift_version    = '5.0'
end
