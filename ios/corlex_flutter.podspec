#
# Run `pod lib lint corlex_flutter.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'corlex_flutter'
  s.version          = '0.1.0'
  s.summary          = 'Corlex analytics for Flutter: events, crashes, Remote Config, A/B tests.'
  s.description      = <<-DESC
The thin native layer of the Corlex Flutter SDK: device facts, the native crash reporter
(NSException and fatal signals) and the App Tracking Transparency status. Events are Dart.
                       DESC
  s.homepage         = 'https://github.com/SEI4X/corlex-flutter'
  s.license          = { :type => 'MIT', :file => '../LICENSE' }
  s.author           = 'Corlex'
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*.{swift,c,h}'
  # The C crash handler is a byte-identical copy of packages/sdk-ios/Sources/CCorlexCrash.
  s.public_header_files = 'Classes/CorlexCrash/CorlexCrash.h'
  s.dependency 'Flutter'
  s.platform = :ios, '15.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'
  s.resource_bundles = {'corlex_flutter_privacy' => ['Resources/PrivacyInfo.xcprivacy']}
end
