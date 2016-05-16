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

*SwiftyPromise* is available through [CocoaPods](http://cocoapods.org). To install
it, simply add the following line to your Podfile:

```ruby
pod "SwiftyPromise"
```

## Author

Steven Roebert ([@sroebert](https://github.com/sroebert))

## License

*SwiftyPromise* is available under the MIT license.