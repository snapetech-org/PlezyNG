#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint os_media_controls.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'os_media_controls'
  s.version          = '0.2.4'
  s.summary          = 'OS-level media controls for Flutter'
  s.description      = <<-DESC
A Flutter plugin for integrating with OS-level media controls across iOS, tvOS, macOS, Android, and Windows.
                       DESC
  s.homepage         = 'https://github.com/edde746/media_controls'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'edde746' => 'https://github.com/edde746' }
  s.source           = { :path => '.' }
  s.source_files = 'os_media_controls/Sources/os_media_controls/**/*'
  s.dependency 'Flutter'
  s.ios.deployment_target  = '12.0'
  s.tvos.deployment_target = '13.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'
end
