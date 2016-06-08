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
    case Pending
    
    /// The promise is fulfilled with a specific value.
    case Fulfilled(Value)
    
    /// The promise was rejected with a specific error.
    case Rejected(ErrorType)
}

/**
 The default error type for `Promise<Value>`.
 */
public enum PromiseError : ErrorType {
    /// Generic error which is used by default if the promise is rejected by passing `nil`.
    case Generic
    
    /// Indicating that the promise was cancelled.
    case Cancelled
}

/// Specific type of promise without a value.
public typealias ActionPromise = Promise<Void>

/**
 Promise base class, providing the parent/child connection and a way of cancelling a chain of promises.
 */
public class PromiseBase {
    /**
     The parent of this promise.
     
     This property will be set when for promises created using `then`. It allows
     for chains of promises to be cancelled.
     */
    private weak var parent: PromiseBase?
    
    /**
     Indicates the amount of children of this promise that have not been cancelled.
     
     This value prevents promise at the start of the chain to be cancelled, if there
     are other children that have not yet been cancelled.
     */
    private var nonCancelledChildrenCount: Int = 0
    
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
    public func cancel() -> Bool {
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
 `Fulfilled(Value)`, when the value is available. `Rejected(ErrorType)`, when the value could not be retrieved or
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
public class Promise<Value> : PromiseBase {
    
    // MARK: - Properties
    
    /**
     Barrier queue used for changing the state of the promise in a thread safe way.
     */
    private let barrier = dispatch_queue_create("com.roebert.SwiftyPromise.promise.barrier", DISPATCH_QUEUE_CONCURRENT)
    
    /**
     List of `dispatch_semaphore_t` created when calling the `waitUntilCompleted` method.
     
     These semaphores will be signalled when the promise has either been fulfilled or rejected.
     */
    private var semaphores: [dispatch_semaphore_t] = []
    
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
    public init(error: ErrorType) {
        super.init()
        reject(error)
    }
    
    /**
     Constructs a pending promise.
     
     This is the main designated initializer, which provides a block for fulfilling and rejecting the promise.
     
     - parameter block: A block which will be executed directly, which can throw an error which will reject the promise.
        
        The block takes three arguments:
        
        `promise`: The constructed promise.<br/>
        `fulfill`: The block to fulfill the promise with a value.<br/>
        `reject`: The block to reject the promise with an error.<br/>
     */
    public init(@noescape _ block: (promise: Promise<Value>, fulfill: (Value) -> Void, reject: (ErrorType) -> Void) throws -> Void) {
        super.init()
        
        do {
            try block(promise: self, fulfill: fulfill, reject: reject)
        } catch let error {
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
    public init<T>(parent: Promise<T>, @noescape _ block: (promise: Promise<Value>, fulfill: (Value) -> Void, reject: (ErrorType) -> Void) throws -> Void) {
        super.init()
        
        do {
            try block(promise: self, fulfill: fulfill, reject: reject)
        } catch let error {
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
    private var unsafeStatus: PromiseStatus<Value> = .Pending {
        didSet {
            switch unsafeStatus {
            case .Fulfilled(let result):
                for (callback, queue) in succeededCallbacks {
                    Promise.dispatch(on: queue) {
                        callback(result)
                    }
                }
                self.detach()
                
            case .Rejected(let error):
                for (callback, queue) in failedCallbacks {
                    Promise.dispatch(on: queue) {
                        callback(error)
                    }
                }
                self.detach()
                
            case .Pending:
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
            dispatch_sync(barrier) {
                status = self.unsafeStatus
            }
            return status
        }
        set {
            dispatch_barrier_sync(barrier) {
                if case .Pending = self.unsafeStatus {
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
        guard case .Fulfilled(let value) = status else {
            return nil
        }
        return value
    }
    
    /**
     If the promise has been rejected, returns the error of the promise, `nil` otherwise.
     */
    public final var error: ErrorType? {
        guard case .Rejected(let error) = status else {
            return nil
        }
        return error
    }
    
    /**
     Indicates whether the promise is completed (i.e. not pending).
     */
    public final var completed: Bool {
        switch status {
        case .Pending:
            return false
        case .Fulfilled, .Rejected:
            return true
        }
    }
    
    /**
     Indicates whether the promise has been fulfilled.
     */
    public final var fulfilled: Bool {
        switch status {
        case .Pending, .Rejected:
            return false
        case .Fulfilled:
            return true
        }
    }
    
    /**
     Fulfilles the promise with a specific value.
     
     This method does nothing if the promise was already fulfilled or rejected.
     */
    private func fulfill(value: Value) {
        status = .Fulfilled(value)
    }
    
    /**
     Indicates whether the promise has been rejected.
     */
    public final var rejected: Bool {
        switch status {
        case .Pending, .Fulfilled:
            return false
        case .Rejected:
            return true
        }
    }
    
    /**
     Rejects the promise with a specific error.
     
     This method does nothing if the promise was already fulfilled or rejected.
     */
    private func reject(error: ErrorType? = nil) {
        status = .Rejected(error ?? PromiseError.Generic)
    }
    
    // MARK: - Callbacks
    
    /**
     The alias for the success callbacks of the promise.
     
     The block contains a single parameter which is the value with which the
     promise was fulfilled.
     */
    public typealias SucceededCallback = (Value) -> Void
    
    /// The array containing all success callbacks.
    private var succeededCallbacks: [(SucceededCallback, dispatch_queue_t?)] = []
    
    /**
     The alias for the failure callbacks of the promise.
     
     The block contains a single parameter which is the error with which the
     promise was rejected.
     */
    public typealias FailedCallback = (ErrorType) -> Void
    
    /// The array containing all failure callbacks.
    private var failedCallbacks: [(FailedCallback, dispatch_queue_t?)] = []
    
    // MARK: - Then
    
    /**
     Dispatches block asynchronously, unless the queue is `nil` and the current
     thread is the main thread.
     
     - parameter queue: The queue on which to dispatch the block or `nil` to dispatch on the main thread.
     - parameter block: The block to dispatch.
     */
    private class func dispatch(on queue: dispatch_queue_t?, block: dispatch_block_t) {
        if let queue = queue {
            dispatch_async(queue, block)
        }
        else if NSThread.isMainThread() {
            block()
        }
        else {
            dispatch_async(dispatch_get_main_queue(), block)
        }
    }
    
    /**
     Creates a new promise which will be fulfilled once both this promise and the one
     returned from the `then` block are fulfilled.
     
     If either this promise is rejected, the `then` block throws an error or the promise
     returned from the `then` block is rejected, the returned promise will be rejected.
     
     - parameter queue: The queue on which to perform the `then` block or `nil` to dispatch on the main thread.
     - parameter then:  A block returning a new promise.
        
        This block will be performed after this promise has been fulfilled. If this promise is rejected,
        the block will not be performed.
     
        The block should return a new promise which returns fulfills with the data the returned promise
        will also be fulfilled.
     
        If the block throws an error, the returned promise will be rejected with the same error.
     
     - returns: A new promise, combining this promise and the one returned from `then`.
     */
    public func then<U>(on queue: dispatch_queue_t? = nil, then: (Value) throws -> Promise<U>) -> Promise<U> {
        return Promise<U>(parent: self) { (_, fulfill, reject) in
            success { value in
                Promise.dispatch(on: queue) {
                    do {
                        let nextPromise = try then(value)
                        nextPromise.success(fulfill).failure(reject)
                    } catch {
                        reject(error)
                    }
                }
            }.failure(reject)
        }
    }
    
    /**
     Creates a new promise which will be fulfilled when this promise is fulfilled and the
     `then` block has returned a value.
     
     If either this promise is rejected or the `then` block throws an error, the returned
     promise will be rejected.
     
     - parameter queue: The queue on which to perform the `then` block or `nil` to dispatch on the main thread.
     - parameter then:  A block returning a value with which the returned promise will be fulfilled.
     
     - returns: A new promise, combining this promise and the value returned from `then`.
     */
    public func then<U>(on queue: dispatch_queue_t? = nil, then: (Value) throws -> U) -> Promise<U> {
        return Promise<U>(parent: self) { (_, fulfill, reject) in
            self.success { value in
                Promise.dispatch(on: queue) {
                    do {
                        let nextValue = try then(value)
                        fulfill(nextValue)
                    } catch {
                        reject(error)
                    }
                }
            }.failure(reject)
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
    public func success(callback: SucceededCallback?) -> Self {
        guard let callback = callback else {
            return self
        }
        return success(on: dispatch_get_main_queue(), callback: callback)
    }
    
    /**
     Adds a success callback to the promise.
     
     This callback will be called once this promise has been fulfilled.
     
     - parameter queue: The queue on which to perform the `callback` block or `nil` to dispatch on the main thread.
     - parameter callback: The callback to call when the promise is fulfilled.
     
     - returns: This promise, allowing to chain multiple callbacks together.
     */
    public func success(on queue: dispatch_queue_t?, callback: SucceededCallback) -> Self {
        switch status {
        case .Fulfilled(let result):
            Promise.dispatch(on: queue) {
                callback(result)
            }
            
        case .Rejected:
            break
            
        case .Pending:
            dispatch_barrier_sync(barrier) {
                switch self.unsafeStatus {
                case .Fulfilled(let result):
                    Promise.dispatch(on: queue) {
                        callback(result)
                    }
                    
                case .Rejected:
                    break
                    
                case .Pending:
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
    public func failure(callback: FailedCallback?) -> Self {
        guard let callback = callback else {
            return self
        }
        return failure(on: dispatch_get_main_queue(), callback: callback)
    }
    
    /**
     Adds a failure callback to the promise.
     
     This callback will be called once this promise has been rejected.
     
     - parameter queue: The queue on which to perform the `callback` block or `nil` to dispatch on the main thread.
     - parameter callback: The callback to call when the promise is rejected.
     
     - returns: This promise, allowing to chain multiple callbacks together.
     */
    public func failure(on queue: dispatch_queue_t, callback: FailedCallback) -> Self {
        switch status {
        case .Fulfilled:
            break
            
        case .Rejected(let error):
            Promise.dispatch(on: queue) {
                callback(error)
            }
            
        case .Pending:
            dispatch_barrier_sync(barrier) {
                switch self.unsafeStatus {
                case .Fulfilled:
                    break
                    
                case .Rejected(let error):
                    Promise.dispatch(on: queue) {
                        callback(error)
                    }
                    
                case .Pending:
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
     
     - parameter queue: The queue on which to perform the `body` block or `nil` to dispatch on the main thread.
     - parameter body:  A block returning a new promise.
        
        This block will be performed when this promise has been rejected. If this promise is fulfilled,
        the block will not be performed.
     
        The block should return a new promise with the same value type as this promise.
     
        If the block throws an error, the returned promise will be rejected with the same error.
     
     - returns: A new promise, which allows recovery if this promise is rejected.
     */
    public func recover(on queue: dispatch_queue_t? = nil, body: (ErrorType) throws -> Promise<Value>) -> Promise<Value> {
        return Promise<Value>(parent: self) { (_, fulfill, reject) in
            success(fulfill).failure { error in
                Promise.dispatch(on: queue) {
                    do {
                        let nextPromise = try body(error)
                        nextPromise.success(fulfill).failure(reject)
                    } catch {
                        reject(error)
                    }
                }
            }
        }
    }
    
    /**
     Creates a new promise allowing to recover if the this promise is rejected.
     
     By providing a block that returns a value of the same type, the resulting promise can
     still be fulfilled.
     
     If the original promise is fulfilled, this new promise will also directly be fulfilled.
     
     - parameter queue: The queue on which to perform the `body` block or `nil` to dispatch on the main thread.
     - parameter body:  A block returning a value with which the returned promise will be fulfilled.
     
        This block will be performed when this promise has been rejected. If this promise is fulfilled,
        the block will not be performed.
         
        The block should return a value of the same type as this promise.
     
        If the block throws an error, the returned promise will be rejected with the same error.
     
     - returns: A new promise, which allows recovery if this promise is rejected.
     */
    public func recover(on queue: dispatch_queue_t? = nil, body: (ErrorType) throws -> Value) -> Promise<Value> {
        return Promise<Value>(parent: self) { (_, fulfill, reject) in
            success(fulfill).failure { error in
                Promise.dispatch(on: queue) {
                    do {
                        let nextValue = try body(error)
                        fulfill(nextValue)
                    } catch {
                        reject(error)
                    }
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
    public override func cancel() -> Bool {
        guard case .Pending = status where isCancellable else {
            return false
        }
        
        if super.cancel() {
            reject(PromiseError.Cancelled)
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
    public func onCancel(callback: () -> Void) -> Self {
        return self.failure { (error) in
            if let promiseError = error as? PromiseError where promiseError == .Cancelled  {
                callback()
            }
        }
    }
    
    // MARK: - Finally
    
    /**
     Adds a callback to be called when the promise is either fulfilled or rejected.
     
     - parameter callback: The callback to call when this promise is either fulfilled or rejected.
     
     - returns: This promise, allowing to chain multiple callbacks together.
     */
    public func finally(callback: (() -> Void)?) -> Self {
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
    public func map<U>(converter: (Value) -> U) -> Promise<U> {
        return then { converter($0) }
    }
    
    /**
     Converts the current promise into an `ActionPromise`.
     
     This is a convenience method that calls the `then` method to convert to an `ActionPromise`.
     
     - returns: The mapped `ActionPromise`.
     */
    public func mapToActionPromise() -> ActionPromise {
        return then { (_) -> Void in }
    }
    
    /**
     Returns a promise that will be fulfilled after this promise which cannot
     be cancelled.
     
     This can be used to return a promise to the UI, while avoiding the original promise
     to be cancelled.
     */
    public func nonCancellablePromise() -> Promise<Value> {
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
            dispatch_semaphore_signal(semaphore)
        }
    }
    
    // MARK: - Wait

    /**
     Waits for this promise to be fulfilled or rejected.
     
     If the promise has already been completed, this method
     returns directly.
     
     This method makes use of `dispatch_semaphore_create` and `dispatch_semaphore_wait`.
     */
    public func waitUntilCompleted() {
        var semaphore: dispatch_semaphore_t? = nil
        
        dispatch_barrier_sync(barrier) {
            guard case .Pending = self.unsafeStatus else {
                return
            }
            
            semaphore = dispatch_semaphore_create(0)
            self.semaphores.append(semaphore!)
        }
        
        if semaphore != nil {
            dispatch_semaphore_wait(semaphore!, DISPATCH_TIME_FOREVER)
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
public func firstly<T>(@noescape block: () throws -> Promise<T>) -> Promise<T> {
    do {
        return try block()
    } catch {
        return Promise<T>(error: error)
    }
}
