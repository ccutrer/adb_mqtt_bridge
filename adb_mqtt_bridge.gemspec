require_relative "lib/adb/version"

Gem::Specification.new do |s|
  s.name = 'adb_mqtt_bridge'
  s.version = ADB::VERSION
  s.platform = Gem::Platform::RUBY
  s.authors = ["Cody Cutrer"]
  s.email = "cody@cutrer.com'"
  s.homepage = "https://github.com/ccutrer/adb_mqtt_bridge"
  s.summary = "Homie MQTT Bridge to automate control of Android devices"
  s.license = "MIT"

  s.executables = ['adb_mqtt_bridge']
  s.files = Dir["{bin,lib}/**/*"]

  s.add_dependency 'mqtt', "~> 0.5.0"

  s.add_development_dependency 'byebug', "~> 9.0"
  s.add_development_dependency 'rake', "~> 13.0"
end
