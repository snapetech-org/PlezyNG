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
  s.dependency 'FlutterMacOS'
  s.platform = :osx, '10.14'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.0'
end
