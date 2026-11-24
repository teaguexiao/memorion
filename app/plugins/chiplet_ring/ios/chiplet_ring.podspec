Pod::Spec.new do |s|
  s.name = 'chiplet_ring'
  s.version = '0.1.0'
  s.summary = 'Memorion CoreBluetooth adapter for ChipletRing.'
  s.description = s.summary
  s.homepage = 'https://github.com/BravechipSpace/ChipletRing-APPSDK'
  s.license = { :type => 'MIT', :file => '../../../../LICENSE' }
  s.author = 'Memorion'
  s.source = { :path => '.' }
  s.source_files = 'Classes/**/*.swift'
  s.dependency 'Flutter'
  s.platform = :ios, '15.0'
  s.swift_version = '5.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
