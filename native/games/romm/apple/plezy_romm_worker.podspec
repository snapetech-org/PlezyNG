Pod::Spec.new do |s|
  s.name = 'plezy_romm_worker'
  s.version = '1.0.0'
  s.summary = 'Isolated Pleazyng emulator worker and bundled cores'
  s.homepage = 'https://github.com/snapetech-org/pleazyng'
  s.license = { :type => 'GPL-3.0-or-later', :file => '../NOTICE.md' }
  s.author = { 'Pleazyng' => 'https://github.com/snapetech-org' }
  s.source = { :path => '.' }
  s.platform = :ios, '26.0'
  s.vendored_frameworks = [
    'Frameworks/ios/PlezyRetroWorker.xcframework',
    'Frameworks/ios/gambatte_libretro.xcframework',
    'Frameworks/ios/mgba_libretro.xcframework',
    'Frameworks/ios/fceumm_libretro.xcframework'
  ]
end
