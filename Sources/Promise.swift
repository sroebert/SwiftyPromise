//
//  Promise.swift
//  SwiftyPromise
//
//  Created by Steven Roebert on 16/05/16.
//  Copyright © 2016 Steven Roebert. All rights reserved.
//

import Foundation

/**
 The status of a `Promise<Value>`.
 */
public enum PromiseStatus<Value> {
    /// The promise is still pending, waiting to be fulfilled or rejected.
    case pending
    
    /// The promise is fulfilled with a specific value.
    case fulfilled(Value)
    
    /// The promise was rejected with a specific error.
    case rejected(Error)
}

/**
 The default error type for `Promise<Value>`.
 */
public enum PromiseError : Error {
    /// Generic error which is used by default if the promise is rejected by passing `nil`.
    case generic
    
    /// Indicating that the promise was cancelled.
    case cancelled
}

/// Specific type of promise without a value.
public typealias ActionPromise = Promise<Void>

/**
 Promise base class, providing the parent/child connection and a way of cancelling a chain of promises.
 */
open class PromiseBase {
    /**
     The parent of this promise.
     
     This property will be set when for promises created using `then`. It allows
     for chains of promises to be cancelled.
     */
    fileprivate weak var parent: PromiseBase?
    
    /**
     Indicates the amount of children of this promise that have not been cancelled.
     
     This value prevents promise at the start of the chain to be cancelled, if there
     are other children that have not yet been cancelled.
     */
    fileprivate var nonCancelledChildrenCount: Int = 0
    
    deinit {
        if let parent = self.parent {
            parent.nonCancelledChildrenCount -= 1
        }
    }
    
    /**
     Cancels the promise.
     
     If this promise has children which are not cancelled, this promise will also not be cancelled.
     
     All parents of this promise without children will also be cancelled.
     
     Children are created using the `then` functions.
     
     - returns: `true` if the promise was cancelled, `false` otherwise.
     */
    @discardableResult open func cancel() -> Bool {
        if self.nonCancelledChildrenCount > 0 {
            return false
        }
        
        if let parent = self.parent {
            parent.nonCancelledChildrenCount -= 1
            if parent.nonCancelledChildrenCount == 0 {
                parent.cancel()
            }
        }
        
        return true
    }
}

/**
 Helper class for cases where a certain value is expected, but will be retrieved or calculated asynchronously.
 
 The class has a state which has three possible options. `Pending`, indicating that the value is not available yet.
 `Fulfilled(Value)`, when the value is available. `Rejected(Error)`, when the value could not be retrieved or
 calculated.
 
 The class has multiple methods for adding callbacks which will be invoked when the status of the `Promise` changes.
 The main methods here are `success`, `failure` and `finally`.
 
 It is also possible to chain promises by calling the `then` methods. This way retrieving a certain value can be achieved
 in multiple steps.
 
 - note: This class if fully thread safe.
 
 Example:
 ```
 let promise: Promise<String> = Promise { (promise, fulfill, reject) in
     dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0)) {
         let string = someMethodThatCreatesAString()
         fulfill(string)
     }
 }
 
 promise.success { (string) in
    print("The promised string is: \(string)")
 }
 ```
 */
open class Promise<Value> : PromiseBase {
    
    // MARK: - Properties
    
    /**
     Barrier queue used for changing the state of the promise in a thread safe way.
     */
    private let barrier = DispatchQueue(label: "com.roebert.SwiftyPromise.promise.barrier", attributes: .concurrent)
    
    /**
     List of `dispatch_semaphore_t` created when calling the `waitUntilCompleted` method.
     
     These semaphores will be signalled when the promise has either been fulfilled or rejected.
     */
    private var semaphores: [DispatchSemaphore] = []
    
    // MARK: - Initialize
    
    /**
     Constructs a promise that is fulfilled with a given value.
     
     - parameter value: The value to fulfill the promise with.
     */
    public init(value: Value) {
        super.init()
        fulfill(value)
    }
    
    /**
     Constructs a promise that is rejected with a given error.
    
     - parameter error: The error to reject the promise with.
     */
    public init(error: Error) {
        super.init()
        reject(error)
    }
    
    /**
     Constructs a pending promise.
     
     This is a designated initializer, which provides a block for fulfilling and rejecting the promise.
     
     - parameter work: A block which will be executed directly, which can throw an error which will reject the promise.
        
        The block takes three arguments:
        
        `promise`: The constructed promise.<br/>
        `fulfill`: The block to fulfill the promise with a value.<br/>
        `reject`: The block to reject the promise with an error.<br/>
     */
    public init(execute work: (_ promise: Promise<Value>, _ fulfill: @escaping (Value) -> Void, _ reject: @escaping (Error) -> Void) throws -> Void) {
        super.init()
        
        do {
            try work(self, fulfill, reject)
        }
        catch let error {
            reject(error)
        }
    }
    
    /**
     Constructs a pending promise.
     
     This is a designated initializer, which provides a block for fulfilling and rejecting the promise.
     
     - parameter queue: The queue on which work will be executed asynchronously.
     - parameter work: A block which will be executed directly, which can throw an error which will reject the promise.
        
        The block takes three arguments:
        
        `promise`: The constructed promise.<br/>
        `fulfill`: The block to fulfill the promise with a value.<br/>
        `reject`: The block to reject the promise with an error.<br/>
     */
    public init(on queue: DispatchQueue, execute work: @escaping (_ promise: Promise<Value>, _ fulfill: @escaping (Value) -> Void, _ reject: @escaping (Error) -> Void) throws -> Void) {
        super.init()
        
        queue.async {
            do {
                try work(self, self.fulfill, self.reject)
            }
            catch let error {
                self.reject(error)
            }
        }
    }
    
    /**
     Constructs a promise by calling a throwing method.
     
     This is a designated initializer, which provides a block for fulfilling and rejecting the promise.
     
     - parameter work: A block which will be executed directly, which can throw an error which will reject the promise. It should return a value with which the promise will be fulfilled.
     */
    public init(execute work: () throws -> Value) {
        super.init()
        
        do {
            let value = try work()
            fulfill(value)
        }
        catch let error {
            reject(error)
        }
    }
    
    /**
     Constructs a pending promise connected to a parent promise.
     
     By connecting to a parent promise, cancelling this promise will also result in cancelling the parent.
     
     - paramater parent:    The parent promise for the newly constructed promise.
     - parameter block:     A block which will be executed directly, which can throw an error which will reject the promise.
        
        The block takes three arguments:
        
        `promise`: The constructed promise.<br/>
        `fulfill`: The block to fulfill the promise with a value.<br/>
        `reject`: The block to reject the promise with an error.<br/>
     */
    public init<T>(parent: Promise<T>, _ block: (_ promise: Promise<Value>, _ fulfill: @escaping (Value) -> Void, _ reject: @escaping (Error) -> Void) throws -> Void) {
        super.init()
        
        do {
            try block(self, fulfill, reject)
        }
        catch let error {
            reject(error)
        }
        
        self.parent = parent
        parent.nonCancelledChildrenCount += 1
    }
    
    // MARK: - Status
    
    /**
     The current status of the promise.
     
     This property is not thread safe and should only be called synchronously on the `barrier` queue. As an
     alternative there is the thread safe property `status`.
     */
    private var unsafeStatus: PromiseStatus<Value> = .pending {
        didSet {
            switch unsafeStatus {
            case .fulfilled(let result):
                for (callback, queue) in succeededCallbacks {
                    queue.async(allowSynchronousOnMain: false) {
                        callback(result)
                    }
                }
                detach()
                
            case .rejected(let error):
                for (callback, queue) in failedCallbacks {
                    queue.async(allowSynchronousOnMain: false) {
                        callback(error)
                    }
                }
                detach()
                
            case .pending:
                break
            }
        }
    }
    
    /**
     The current status of the promise.
     */
    public final var status: PromiseStatus<Value> {
        get {
            var status: PromiseStatus<Value>!
            barrier.sync {
                status = self.unsafeStatus
            }
            return status
        }
        set {
            barrier.sync(flags: .barrier) {
                if case .pending = self.unsafeStatus {
                    self.unsafeStatus = newValue
                }
            }
        }
    }
    
    // MARK: - Public Properties
    
    /**
     If the promise has been fulfilled, returns the value of the promise, `nil` otherwise.
     */
    public final var value: Value? {
        guard case .fulfilled(let value) = status else {
            return nil
        }
        return value
    }
    
    /**
     If the promise has been rejected, returns the error of the promise, `nil` otherwise.
     */
    public final var error: Error? {
        guard case .rejected(let error) = status else {
            return nil
        }
        return error
    }
    
    /**
     Indicates whether the promise is completed (i.e. not pending).
     */
    public final var completed: Bool {
        switch status {
        case .pending:
            return false
        case .fulfilled, .rejected:
            return true
        }
    }
    
    /**
     Indicates whether the promise has been fulfilled.
     */
    public final var fulfilled: Bool {
        switch status {
        case .pending, .rejected:
            return false
        case .fulfilled:
            return true
        }
    }
    
    /**
     Fulfilles the promise with a specific value.
     
     This method does nothing if the promise was already fulfilled or rejected.
     */
    private func fulfill(_ value: Value) {
        status = .fulfilled(value)
    }
    
    /**
     Indicates whether the promise has been rejected.
     */
    public final var rejected: Bool {
        switch status {
        case .pending, .fulfilled:
            return false
        case .rejected:
            return true
        }
    }
    
    /**
     Rejects the promise with a specific error.
     
     This method does nothing if the promise was already fulfilled or rejected.
     */
    private func reject(_ error: Error) {
        status = .rejected(error)
    }
    
    // MARK: - Callbacks
    
    /**
     The alias for the success callbacks of the promise.
     
     The block contains a single parameter which is the value with which the
     promise was fulfilled.
     */
    public typealias SucceededCallback = (Value) -> Void
    
    /// The array containing all success callbacks.
    private var succeededCallbacks: [(SucceededCallback, DispatchQueue)] = []
    
    /**
     The alias for the failure callbacks of the promise.
     
     The block contains a single parameter which is the error with which the
     promise was rejected.
     */
    public typealias FailedCallback = (Error) -> Void
    
    /// The array containing all failure callbacks.
    private var failedCallbacks: [(FailedCallback, DispatchQueue)] = []
    
    // MARK: - Then
    
    /**
     Creates a new promise which will be fulfilled once both this promise and the one
     returned from the `body` block are fulfilled.
     
     If either this promise is rejected, the `body` block throws an error or the promise
     returned from the `body` block is rejected, the returned promise will be rejected.
     
     - parameter queue: The queue on which to perform the `body` block.
     - parameter body:  A block returning a new promise.
        
        This block will be performed after this promise has been fulfilled. If this promise is rejected,
        the block will not be performed.
     
        The block should return a new promise for the expected new value type.
     
        If the block throws an error, the returned promise will be rejected with the same error.
     
     - returns: A new promise, combining this promise and the one returned from `body`.
     */
    @discardableResult open func then<U>(on queue: DispatchQueue = .main, body: @escaping (Value) throws -> Promise<U>) -> Promise<U> {
        return Promise<U>(parent: self) { (_, fulfill, reject) in
            success(on: queue) { value in
                do {
                    let nextPromise = try body(value)
                    nextPromise.success(fulfill).failure(reject)
                }
                catch {
                    reject(error)
                }
            }.failure(on: queue, callback: reject)
        }
    }
    
    /**
     Creates a new promise which will be fulfilled when this promise is fulfilled and the
     `body` block has returned a value.
     
     If either this promise is rejected or the `body` block throws an error, the returned
     promise will be rejected.
     
     - parameter queue: The queue on which to perform the `body` block.
     - parameter body:  A block returning a value with which the returned promise will be fulfilled.
     
        This block will be performed after this promise has been fulfilled. If this promise is rejected,
        the block will not be performed.
     
        The block should return a value of the newly expected type.
     
        If the block throws an error, the returned promise will be rejected with the same error.
     
     - returns: A new promise, combining this promise and the value returned from `body`.
     */
    @discardableResult open func then<U>(on queue: DispatchQueue = .main, body: @escaping (Value) throws -> U) -> Promise<U> {
        return Promise<U>(parent: self) { (_, fulfill, reject) in
            self.success(on: queue) { value in
                do {
                    let nextValue = try body(value)
                    fulfill(nextValue)
                }
                catch {
                    reject(error)
                }
            }.failure(on: queue, callback: reject)
        }
    }
    
    /**
     Creates a new promise which will be fulfilled when this promise is fulfilled and the fulfill callback
     passed to the `body` block has been called.
     
     If either this promise is rejected or the reject callback passed to the `body` block is called or the `body`
     block throws an error, the returned promise will be rejected.
     
     - parameter queue: The queue on which to perform the `body` block.
     - parameter body:  A block which is responsible for calling either fulfill or reject to respectively fulfill or reject
        the promise.
     
        This block will be performed after this promise has been fulfilled. If this promise is rejected,
        the block will not be performed.
     
        If the block throws an error, the returned promise will be rejected with the same error.
     
     - returns: A new promise, combining this promise and the value returned from `body`.
     */
    @discardableResult open func thenWithCallbacks<U>(on queue: DispatchQueue = .main, body: @escaping (Value, @escaping (U) -> Void, @escaping (Error) -> Void) throws -> Void) -> Promise<U> {
        return Promise<U>(parent: self) { (_, fulfill, reject) in
            self.success(on: queue) { value in
                do {
                    try body(value, fulfill, reject)
                }
                catch {
                    reject(error)
                }
            }.failure(on: queue, callback: reject)
        }
    }
    
    // MARK: - Success / Failure
    
    /**
     Adds a success callback to the promise.
     
     This callback will be called once this promise has been fulfilled. The callback will
     be called on the main thread.
     
     - parameter callback: The callback to call when the promise is fulfilled.
     
     - returns: This promise, allowing to chain multiple callbacks together.
     */
    @discardableResult open func success(_ callback: SucceededCallback?) -> Self {
        guard let callback = callback else {
            return self
        }
        return success(on: .main, callback: callback)
    }
    
    /**
     Adds a success callback to the promise.
     
     This callback will be called once this promise has been fulfilled.
     
     - parameter queue: The queue on which to perform the `callback` block.
     - parameter callback: The callback to call when the promise is fulfilled.
     
     - returns: This promise, allowing to chain multiple callbacks together.
     */
    @discardableResult open func success(on queue: DispatchQueue, callback: @escaping SucceededCallback) -> Self {
        switch status {
        case .fulfilled(let result):
            queue.async(allowSynchronousOnMain: true) {
                callback(result)
            }
            
        case .rejected:
            break
            
        case .pending:
            barrier.sync(flags: .barrier) {
                switch self.unsafeStatus {
                case .fulfilled(let result):
                    queue.async(allowSynchronousOnMain: true) {
                        callback(result)
                    }
                    
                case .rejected:
                    break
                    
                case .pending:
                    self.succeededCallbacks.append((callback, queue))
                }
            }
        }
        return self
    }
    
    /**
     Adds a failure callback to the promise.
     
     This callback will be called once this promise has been rejected. The callback will
     be called on the main thread.
     
     - parameter callback: The callback to call when the promise is rejected.
     
     - returns: This promise, allowing to chain multiple callbacks together.
     */
    @discardableResult open func failure(_ callback: FailedCallback?) -> Self {
        guard let callback = callback else {
            return self
        }
        return failure(on: .main, callback: callback)
    }
    
    /**
     Adds a failure callback to the promise.
     
     This callback will be called once this promise has been rejected.
     
     - parameter queue: The queue on which to perform the `callback` block.
     - parameter callback: The callback to call when the promise is rejected.
     
     - returns: This promise, allowing to chain multiple callbacks together.
     */
    @discardableResult open func failure(on queue: DispatchQueue, callback: @escaping FailedCallback) -> Self {
        switch status {
        case .fulfilled:
            break
            
        case .rejected(let error):
            queue.async(allowSynchronousOnMain: true) {
                callback(error)
            }
            
        case .pending:
            barrier.sync(flags: .barrier) {
                switch self.unsafeStatus {
                case .fulfilled:
                    break
                    
                case .rejected(let error):
                    queue.async(allowSynchronousOnMain: true) {
                        callback(error)
                    }
                    
                case .pending:
                    self.failedCallbacks.append((callback, queue))
                }
            }
        }
        return self
    }
    
    // MARK: - Recover
    
    /**
     Creates a new promise allowing to recover if the this promise is rejected.
     
     By providing a block that returns a new promise with the same expected value type, the
     resulting promise can still be fulfilled.
     
     If the original promise is fulfilled, this new promise will also directly be fulfilled.
     
     - parameter queue: The queue on which to perform the `body` block.
     - parameter body:  A block returning a new promise.
        
        This block will be performed when this promise has been rejected. If this promise is fulfilled,
        the block will not be performed.
     
        The block should return a new promise with the same value type as this promise.
     
        If the block throws an error, the returned promise will be rejected with the same error.
     
     - returns: A new promise, which allows recovery if this promise is rejected.
     */
    @discardableResult open func recover(on queue: DispatchQueue = .main, body: @escaping (Error) throws -> Promise<Value>) -> Promise<Value> {
        return Promise<Value>(parent: self) { (_, fulfill, reject) in
            success(on: queue, callback: fulfill).failure(on: queue) { originalError in
                do {
                    let nextPromise = try body(originalError)
                    nextPromise.success(fulfill).failure(reject)
                }
                catch {
                    reject(error)
                }
            }
        }
    }
    
    /**
     Creates a new promise allowing to recover if the this promise is rejected.
     
     By providing a block that returns a value of the same type, the resulting promise can
     still be fulfilled.
     
     If the original promise is fulfilled, this new promise will also directly be fulfilled.
     
     - parameter queue: The queue on which to perform the `body` block.
     - parameter body:  A block returning a value with which the returned promise will be fulfilled.
     
        This block will be performed when this promise has been rejected. If this promise is fulfilled,
        the block will not be performed.
         
        The block should return a value of the same type as this promise.
     
        If the block throws an error, the returned promise will be rejected with the same error.
     
     - returns: A new promise, which allows recovery if this promise is rejected.
     */
    @discardableResult open func recover(on queue: DispatchQueue = .main, body: @escaping (Error) throws -> Value) -> Promise<Value> {
        return Promise<Value>(parent: self) { (_, fulfill, reject) in
            success(on: queue, callback: fulfill).failure(on: queue) { originalError in
                do {
                    let nextValue = try body(originalError)
                    fulfill(nextValue)
                }
                catch {
                    reject(error)
                }
            }
        }
    }
    
    /**
     Creates a new promise allowing to recover if the this promise is rejected.
     
     By providing a block which will have new methods for fulfilling or rejecting, the resulting promise can
     still be fulfilled.
     
     If the original promise is fulfilled, this new promise will also directly be fulfilled.
     
     - parameter queue: The queue on which to perform the `body` block.
     - parameter body:  A block which is responsible for calling either fulfill or reject to respectively fulfill or reject
        the promise.
     
        This block will be performed when this promise has been rejected. If this promise is fulfilled,
        the block will not be performed.
         
        The block should return a value of the same type as this promise.
     
        If the block throws an error, the returned promise will be rejected with the same error.
     
     - returns: A new promise, which allows recovery if this promise is rejected.
     */
    @discardableResult open func recoverWithCallbacks(on queue: DispatchQueue = .main, body: @escaping (Error, @escaping (Value) -> Void, @escaping (Error) -> Void) throws -> Void) -> Promise<Value> {
        return Promise<Value>(parent: self) { (_, fulfill, reject) in
            success(on: queue, callback: fulfill).failure(on: queue) { error in
                do {
                    try body(error, fulfill, reject)
                }
                catch {
                    reject(error)
                }
            }
        }
    }
    
    // MARK: - Cancel
    
    /**
     Cancels the promise.
     
     If this promise has children which are not cancelled, this promise will also not be cancelled.
     
     All parents of this promise without children will also be cancelled.
     
     Children are created using the `then` functions.
     
     - returns: `true` if the promise was cancelled, `false` otherwise.
     */
    @discardableResult open override func cancel() -> Bool {
        guard case .pending = status, isCancellable else {
            return false
        }
        
        if super.cancel() {
            reject(PromiseError.cancelled)
            return true
        }
        return false
    }
    
    /**
     Indicates whether this promise can be cancelled.
     */
    private(set) var isCancellable: Bool = true
    
    /**
     Adds a callback to be called when the promise is cancelled.
     
     - parameter callback: The callback to call when this promise is cancelled.
     
     - returns: This promise, allowing to chain multiple callbacks together.
     */
    @discardableResult open func onCancel(_ callback: @escaping () -> Void) -> Self {
        return self.failure { error in
            switch error {
            case PromiseError.cancelled:
                callback()
                
            default:
                break
            }
        }
    }
    
    // MARK: - Finally
    
    /**
     Adds a callback to be called when the promise is either fulfilled or rejected.
     
     - parameter callback: The callback to call when this promise is either fulfilled or rejected.
     
     - returns: This promise, allowing to chain multiple callbacks together.
     */
    @discardableResult open func finally(_ callback: (() -> Void)?) -> Self {
        guard callback != nil else {
            return self
        }
        
        return self.success({ _ in callback!() }).failure({ _ in callback!() })
    }
    
    // MARK: - Utils
    
    /**
     Maps the promise to a new promise with a different type of value.
     
     This is a convenience method that calls the `then` method with the passed converter.
     
     - parameter converter: Converter to convert the value of this promise
     into the value for the mapped promise.
     
     - returns: The mapped promise.
     */
    open func map<U>(_ converter: @escaping (Value) -> U) -> Promise<U> {
        return then { converter($0) }
    }

    /**
     Converts the current promise into an `ActionPromise`.
     
     This is a convenience method that calls the `then` method to convert to an `ActionPromise`.

     - returns: The mapped `ActionPromise`.
     */
    open func mapToActionPromise() -> ActionPromise {
        return then { (_) -> Void in }
    }
    
    /**
     Returns a promise that will be fulfilled after this promise which cannot
     be cancelled.
     
     This can be used to return a promise to the UI, while avoiding the original promise
     to be cancelled.
     */
    open func nonCancellablePromise() -> Promise<Value> {
        let promise = then { $0 }
        promise.isCancellable = false
        return promise
    }
    
    // MARK: - Detach
    
    /**
     Called after the promise is fulfilled or rejected.
     
     This method cleans up the callbacks, allowing the promise to be deallocated. It also
     signals all semaphores created by `waitUntilCompleted`.
     */
    private func detach() {
        succeededCallbacks.removeAll()
        failedCallbacks.removeAll()
        
        for semaphore in semaphores {
            semaphore.signal()
        }
    }
    
    // MARK: - Wait

    /**
     Waits for this promise to be fulfilled or rejected.
     
     If the promise has already been completed, this method
     returns directly.
     
     This method makes use of `dispatch_semaphore_create` and `dispatch_semaphore_wait`.
     */
    open func waitUntilCompleted() {
        var semaphore: DispatchSemaphore? = nil
        
        barrier.sync(flags: .barrier) {
            guard case .pending = self.unsafeStatus else {
                return
            }
            
            semaphore = DispatchSemaphore(value: 0)
            self.semaphores.append(semaphore!)
        }
        
        if semaphore != nil {
            _ = semaphore!.wait(timeout: DispatchTime.distantFuture)
        }
    }
}

/**
 Utility method for starting a chain of promises.
 
 This makes the whole chain more readable, starting with `firstly` and
 followed by `then`, `success`, `failure` and `finally`.
 
 ```
 firstly {
    callSomeMethodThatReturnsAPromise()
 }.then {
    callAnotherMethodThatReturnsAPromise()
 }
 ```
 
 - parameter block: The block in which to create the first promise.
 
 - returns: The promise created by `block`.
 */
public func firstly<T>(_ block: () throws -> Promise<T>) -> Promise<T> {
    do {
        return try block()
    }
    catch {
        return Promise<T>(error: error)
    }
}

/**
 Utility method for starting a chain of promises.
 
 This makes the whole chain more readable, starting with `firstly` and
 followed by `then`, `success`, `failure` and `finally`.
 
 ```
 firstly { (fulfill, reject) in
    callSomeMethodWithSuccess(fulfill, failure: reject)
 }.then {
    callAnotherMethodThatReturnsAPromise()
 }
 ```
 
 - parameter block: The block to which a fulfill and reject closure is passed for fulfilling or rejecting
    the returned promise.
 
 - returns: The created promise.
 */
public func firstly<T>(_ block: (@escaping (T) -> Void, @escaping (Error) -> Void) throws -> Void) -> Promise<T> {
    return Promise { (_, fulfill, reject) in
        try block(fulfill, reject)
    }
}

extension DispatchQueue {
    /**
     Dispatches work asynchronously.
     
     - parameter allowSynchronousOnMain: If `true` and dispatching on `main`, the work will be executed synchronously.
     - parameter work: The work to dispatch.
     */
    func async(allowSynchronousOnMain: Bool, execute work: @escaping () -> Void) {
        if allowSynchronousOnMain && self == DispatchQueue.main && Thread.isMainThread {
            work()
        }
        else {
            async(execute: work)
        }
    }
}
