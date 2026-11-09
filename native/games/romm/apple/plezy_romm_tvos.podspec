Pod::Spec.new do |s|
  s.name = 'plezy_romm_tvos'
  s.version = '1.0.0'
  s.summary = 'PlezyNG software libretro game runtime'
  s.homepage = 'https://github.com/snapetech-org/pleazyng'
  s.license = { :type => 'GPL-3.0-or-later', :file => '../NOTICE.md' }
  s.author = { 'PlezyNG' => 'https://github.com/snapetech-org' }
  s.source = { :path => '.' }
  s.platform = :tvos, '15.0'
  s.vendored_frameworks = 'Frameworks/tvos/PlezyRetro.xcframework'
  s.resource_bundles = { 'PleazyngRommNotices' => ['Frameworks/tvos/notices/**/*'] }
end
