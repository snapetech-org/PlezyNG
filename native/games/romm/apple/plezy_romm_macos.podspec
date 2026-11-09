Pod::Spec.new do |s|
  s.name = 'plezy_romm_macos'
  s.version = '1.0.0'
  s.summary = 'PlezyNG software libretro game runtime'
  s.homepage = 'https://github.com/snapetech-org/pleazyng'
  s.license = { :type => 'GPL-3.0-or-later', :file => '../NOTICE.md' }
  s.author = { 'PlezyNG' => 'https://github.com/snapetech-org' }
  s.source = { :path => '.' }
  s.platform = :osx, '14.0'
  s.vendored_frameworks = 'Frameworks/macos/PlezyRetro.xcframework'
  # Cores are copied and signed for the worker, never linked into the app.
  s.preserve_paths = 'Frameworks/macos/*_libretro.xcframework', 'Frameworks/macos/helpers/*'
  s.resource_bundles = { 'PleazyngRommNotices' => ['Frameworks/macos/notices/**/*'] }
end
