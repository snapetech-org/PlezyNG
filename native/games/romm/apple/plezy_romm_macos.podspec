Pod::Spec.new do |s|
  s.name = 'plezy_romm_macos'
  s.version = '1.0.0'
  s.summary = 'PlezyNG software libretro game runtime'
  s.homepage = 'https://github.com/snapetech-org/PlezyNG'
  s.license = { :type => 'GPL-3.0-or-later', :file => '../NOTICE.md' }
  s.author = { 'PlezyNG' => 'https://github.com/snapetech-org' }
  s.source = { :path => '.' }
  s.platform = :osx, '14.0'
  s.vendored_frameworks = 'Frameworks/macos/*.xcframework'
end
