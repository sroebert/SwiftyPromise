Pod::Spec.new do |s|
  s.name             = "SwiftyPromise"
  s.version          = "1.3"
  s.summary          = "A simple promise framework for Swift."

  s.description      = <<-DESC
This small library implements thread safe promises for Swift. It allows to create promises and fulfill or reject them asynchronously. Promises can be chained using the `then` method. Furthermore it has support for cancelling a promise chain.
                       DESC

  s.homepage         = "https://github.com/sroebert/SwiftyPromise"
  s.license          = { :type => 'MIT' }
  s.author           = { "Steven Roebert" => "steven@roebert.nl" }
  s.source           = { :git => "https://github.com/sroebert/SwiftyPromise.git", :tag => "#{s.version}" }
  
  s.requires_arc     = true
  s.source_files     = 'Sources/**/*.{h,swift}'
  s.frameworks       = 'Foundation'
  
  s.ios.deployment_target = '8.0'
  s.osx.deployment_target = '10.9'
  s.watchos.deployment_target = '2.0'
  s.tvos.deployment_target = '9.0'
end
