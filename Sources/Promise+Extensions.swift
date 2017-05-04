//
//  Promise+Extensions.swift
//  SwiftyPromise
//
//  Created by Steven Roebert on 20/02/16.
//  Copyright © 2016 Steven Roebert. All rights reserved.
//

import Foundation

/**
 Utility method for chaining multiple promises of the same type together.
 
 - parameter promises: List of promises for a given type of value.
 
 - returns: A new promise which will be fulfilled when all `promises` are fulfilled.
 */
public func when<U>(_ promises: Promise<U>...) -> Promise<[U]> {
    return when(promises)
}

public func when<U>(_ promises: [Promise<U>]) -> Promise<[U]> {
    
    if promises.isEmpty {
        return Promise<[U]>(value: [])
    }
    
    return Promise<[U]> { (_, fulfill, reject) in
    
        var results = Array<Any>(repeating: NSNull(), count: promises.count)
        var counter = 0
        
        let barrier = DispatchQueue(label: "com.roebert.SwiftyPromise.promise.when", attributes: .concurrent)
        
        for (index, promise) in promises.enumerated() {
            promise.finally {
                barrier.sync(flags: .barrier) {
                    switch promise.status {
                    case .pending:
                        break
                        
                    case .fulfilled(let value):
                        results[index] = value
                        
                        counter += 1
                        if counter == promises.count {
                            fulfill(results.map { $0 as! U })
                        }
                        
                    case .rejected(let error):
                        reject(error)
                    }
                }
            }
        }
    }
}

public extension DispatchQueue {
    public class func promise(after interval: TimeInterval) -> ActionPromise {
        return DispatchQueue.main.promise(after: interval)
    }
    
    public func promise(after interval: TimeInterval) -> ActionPromise {
        return Promise<Void> { (_, fulfill, _) in
            let deadline: DispatchTime = .now() + DispatchTimeInterval(interval: interval)
            asyncAfter(deadline: deadline) {
                fulfill()
            }
        }
    }
}

fileprivate extension DispatchTimeInterval {
    init(interval: TimeInterval) {
        let naneseconds = interval * 1_000_000_000
        if naneseconds <= TimeInterval(Int.max) {
            self = .nanoseconds(Int(naneseconds))
            return
        }
        
        let microseconds = interval * 1_000_000
        if microseconds <= TimeInterval(Int.max) {
            self = .microseconds(Int(microseconds))
            return
        }
        
        let milliseconds = interval * 1_000
        if milliseconds <= TimeInterval(Int.max) {
            self = .milliseconds(Int(milliseconds))
            return
        }
        
        self = .seconds(Int(interval))
    }
}
