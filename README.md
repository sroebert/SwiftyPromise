# SwiftyPromise
A simple promise framework for Swift.

This small library implements thread safe promises for Swift. It allows to create promises and fulfill or reject them asynchronously. Promises can be chained using the `then` method. Furthermore it has support for cancelling a promise chain.

## Usage

```swift
let promise: Promise<String> = Promise { (_, fulfill, reject) in
    performSomeAsynchronousTaskWithCompletion() { (resultString: String?, error: ErrorType?) in
        if let string = resultString {
            fulfill(string)
        }
        else {
            reject(error)
        }
    }
}

promise.success { string in
    print("The result is: \(string)")
}.failure { error in
    print("Something went wrong: \(error)")
}

promise.then { (string) -> AnyObject in
    guard let data = string.dataUsingEncoding(NSUTF8StringEncoding) else {
        throw PromiseError.Generic
    }
    return try NSJSONSerialization.JSONObjectWithData(data, options: [])
}.success { (jsonObject) in
    print("Parsed json object: \(jsonObject)")
}.failure { error in
    print("Could not parse json: \(error)")
}
```

## Installation

Using [CocoaPods](https://cocoapods.org/):

```ruby
use_frameworks!
pod 'SwiftyPromise'
```

Using [Carthage](https://github.com/Carthage/Carthage):

```
github "sroebert/SwiftyPromise"
```

Manually:

1. Drag `SwiftyPromise.xcodeproj` to your project in the _Project Navigator_.
2. Select your project and then your app target. Open the _Build Phases_ panel.
3. Expand the _Target Dependencies_ group, and add `SwiftyPromise.framework`.
4. Click on the `+` button at the top left of the panel and select _New Copy Files Phase_. Set _Destination_ to _Frameworks_, and add `SwiftyPromise.framework`.
5. `import SwiftyPromise` whenever you want to use SwiftyPromise.

## Requirements

- iOS 8.0+, Mac OS X 10.9+, tvOS 9.0+ or watchOS 2.0+
- Swift 3.0

## Author

Steven Roebert ([@sroebert](https://github.com/sroebert))

## License

SwiftyPromise is available under the MIT license.
