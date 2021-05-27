//
//  FASFlux.swift
//  Friendly
//
//  Created by spsadmin on 6/10/16.
//  Copyright © 2016 Friendly App Studio. All rights reserved.
//

import Foundation

public typealias FASFluxCallback = (Any) -> Void


enum FASFluxCallbackType {
  case Func(FASFluxCallback)
}

// CHANGED: new log delegate
public enum FASLogLevel {
  case debug, warn, error
}

public protocol FASFluxDispatcherLogDelegate: class {
  func dispatcherLog(_ sender: Any, level: FASLogLevel, message: String, error: Error?)
}

public class FASFluxDispatcher {
  var lastID : Int = 0
  
  let dispatchQueue : DispatchQueue
  var callbacks : [String : FASFluxCallbackType] = [String : FASFluxCallbackType]()
  var isPending : [String : Bool] = [String : Bool]()
  var isHandled : [String : Bool] = [String : Bool]()
  
  var pendingAction : Any?
  var isDispatching : Bool = false
  
  public weak var logDelegate: FASFluxDispatcherLogDelegate?
  
  init() {
    dispatchQueue = DispatchQueue.main
  }
  
  private func nextRegistrationToken() -> String {
    lastID = lastID + 1
    let token = "token_\(lastID)"
    return token
  }
  
  private func register(callback : FASFluxCallbackType) -> String {
    if !Thread.isMainThread {
      fatalError("Detected unsafe register() call on secondary thread")
    }
    let token = nextRegistrationToken()
    callbacks[token] = callback
    return token
  }
  
  fileprivate func register(fn : @escaping FASFluxCallback, storeType: FASFluxStore.Type) -> String {
    let token = register(callback: .Func(fn))
    log(level: .debug, message: "registration token '\(token)' assigned to store '\(storeType)'")
    return token
  }
  
  fileprivate func unregister(token : String) {
    if !Thread.isMainThread {
      fatalError("Detected unsafe unregister() call on secondary thread")
    }
    if let _ = callbacks[token] {
      callbacks.removeValue(forKey: token)
      isPending.removeValue(forKey: token)
      isHandled.removeValue(forKey: token)
    }
  }
  
  public func waitFor(stores:[FASFluxStore]) {
    if !Thread.isMainThread {
      fatalError("Detected unsafe waitFor() call on secondary thread")
    }
    guard isDispatching else { return }
    for store in stores {
      if let token = store.dispatchToken {
        let pending = isPending[token] ?? false
        let handled = isHandled[token] ?? false
        if pending {
          if handled {
            //            var stack = ""
            //            Thread.callStackSymbols.forEach{stack += "\($0)\n"}
            //            log(level: .debug, message: "Dispatcher waitFor : the callback for '\(type(of: store))' has handled the action already\n\(stack)")
            log(level: .debug, message: "Dispatcher waitFor : the callback for '\(type(of: store))' has handled the action already")
            continue
          } else {
            log(level: .warn, message: "⚠️ Dispatcher waitFor : circular dependency detected while waiting for '\(type(of: store))'")
            continue
          }
        }
        
        if let _ = callbacks[token] {
          invokeCallback(token: token)
        } else {
          log(level: .warn, message: "⚠️ Dispatcher waitFor '\(type(of: store))' does not map to a registered Callback")
        }
      } else {
        log(level: .warn, message: "⚠️ Can't wait for store '\(type(of: store))' because it's not registered")
      }
    }
  }
  
  private func invokeCallback(token : String) {
    if let callback = callbacks[token] {
      isPending[token] = true
      switch callback {
      case .Func(let c) :
        if let pendingAction = pendingAction {
          c(pendingAction)
        }
      }
      isHandled[token] = true
    } else {
      log(level: .warn, message: "⚠️ Can't invoke token (\(token)) as it was unregistered")
    }
  }
  
  private func startDispatching(action : Any) {
    log(level: .debug, message: "startDispatching(action: '\(action))'")
    isPending.removeAll()
    isHandled.removeAll()
    pendingAction = action
    isDispatching = true
  }
  
  private func stopDispatching() {
    pendingAction = nil
    isDispatching = false
  }
  
  private func doDispatch(action:Any) {
    guard !isDispatching else {
      log(level: .error, message: "🛑 Dispatch.dispatchAction cannot dispatch in the middle of a dispatch!")
      return
    }
    autoreleasepool {
      startDispatching(action: action)
      for (token, _) in callbacks {
        if !(isPending[token] ?? false) {
          invokeCallback(token: token)
        }
      }
      stopDispatching()
    }
  }
  
  public func dispatchAction(action : Any) {
    if Thread.isMainThread {
      doDispatch(action: action)
    } else {
      dispatchQueue.sync() {
        [weak self] in
        self?.doDispatch(action: action)
      }
    }
  }
  
  private func log(level: FASLogLevel, message: String, error: Error? = nil) {
    if logDelegate != nil {
      logDelegate!.dispatcherLog(self, level: level, message: message, error: error)
    } else {
      NSLog("%@", message)
    }
  }
}

private let mainDispatcher = FASFluxDispatcher()

extension FASFluxDispatcher {
  public static var main: FASFluxDispatcher {
    return mainDispatcher
  }
}

public protocol FASStoreObserving: class {
  func observeChange(store:FASFluxStore, action: Any?, userInfo: Any?)
}

fileprivate class FASObserverProxy {
  weak var observer: FASStoreObserving?
  init(observer: FASStoreObserving) {
    self.observer = observer
  }
  
  func forwardChange(store: FASFluxStore, action: Any?, userInfo: Any?) -> Bool {
    if let o = observer {
      o.observeChange(store: store, action: action, userInfo: userInfo)
      return true
    }
    return false
  }
}

open class FASFluxStore {
  fileprivate var dispatchToken : String?
  private var observerProxies : [FASObserverProxy] = []
  weak var logDelegate: FASFluxDispatcherLogDelegate?
  private var isEmitting = false
  
  public func registerWithDispatcher(_ dispatcher: FASFluxDispatcher, callback: @escaping FASFluxCallback) {
    if Thread.isMainThread {
      self.logDelegate = dispatcher.logDelegate
      dispatchToken = dispatcher.register(fn: callback, storeType: type(of: self))
    } else {
      log(level: .warn, message: "store '\(type(of: self))' registered with dispatcher on a secondary thread")
      dispatcher.dispatchQueue.sync() { [weak self] in
        if let this = self {
          this.logDelegate = dispatcher.logDelegate
          this.dispatchToken = dispatcher.register(fn: callback, storeType: type(of: this))
        }
      }
    }
  }
  
  func unregisterFromDispatcher(_ dispatcher: FASFluxDispatcher, callback: @escaping FASFluxCallback) {
    if Thread.isMainThread {
      if let dt = dispatchToken {
        dispatcher.unregister(token: dt)
      }
      dispatchToken = nil
    } else {
      log(level: .warn, message: "store '\(type(of: self))' unregistered from dispatcher on a secondary thread")
      dispatcher.dispatchQueue.sync() { [weak self] in
        if let this = self {
          if let dt = this.dispatchToken {
            dispatcher.unregister(token: dt)
          }
          this.dispatchToken = nil
        }
      }
    }
  }
  
  public init() {
    
  }
  
  public func add(observer:FASStoreObserving) {
    checkMainThread(contextString: "add(observer:)")
    let existing = self.observerProxies.first { (proxy: FASObserverProxy) -> Bool in
      proxy.observer === observer
    }
    if existing == nil {
      let weakObserver = FASObserverProxy(observer: observer)
      if isEmitting {
        log(level: .warn, message: "WARN Will add(observer:FASStoreObserving) asynchronously because the store \(type(of: self)) is currently emitting")
        DispatchQueue.main.async {
          self.observerProxies.append(weakObserver)
        }
      } else {
        self.observerProxies.append(weakObserver)
      }
    } else {
      self.log(level: .warn, message: "⚠️ '\(String(describing: observer))' is already observing '\(String(describing: self))'.")
    }
  }
  
  public func remove(observer:FASStoreObserving) {
    checkMainThread(contextString: "remove(observer:)")
    func scanAndRemove() {
      if let index = self.observerProxies.firstIndex(where: { po in return po.observer === observer }) {
        self.observerProxies.remove(at: index)
      }
    }
    if isEmitting {
      log(level: .warn, message: "WARN Will remove(observer:FASStoreObserving) asynchronously because the store \(type(of: self)) is currently emitting")
      DispatchQueue.main.async {
        scanAndRemove()
      }
    } else {
      scanAndRemove()
    }
  }
  
  public func emitChange(_ action: Any? = nil, userInfo: Any? = nil) {
    checkMainThread(contextString: "emitChange()")
    isEmitting = true
    self.observerProxies = observerProxies.filter { $0.forwardChange(store: self, action: action, userInfo: userInfo) }
    isEmitting = false
  }
  
  
  public func emitChange() {
    emitChange(userInfo: nil)
  }
  public func emitChange(asResultOfActionType actionType:String) {
    emitChange(userInfo: ["afterAction":actionType])
  }
  
  public func printObservers() -> String {
    let list = observerProxies.reduce("") { (result: String, observerProxy: FASObserverProxy) -> String in
      var observerString = "nil"
      if observerProxy.observer != nil {
        observerString = "\(type(of: observerProxy.observer!))"
      }
      if result.count > 0 {
        return result + ", \(observerString)"
      } else {
        return result + "\(observerString)"
      }
    }
    return "(\(observerProxies.count) observers) \(list)"
  }
  
  private func checkMainThread(contextString: String) {
    if !Thread.isMainThread {
      log(level: .warn, message: "WARN must be called from the main thread!! (contex=\(contextString)) ")
      #if DEBUG
      abort()
      #endif
    }
  }
  
  
  fileprivate func log(level: FASLogLevel, message: String, error: Error? = nil) {
    if logDelegate != nil {
      logDelegate!.dispatcherLog(self, level: level, message: message, error: error)
    } else {
      NSLog("%@", message)
    }
  }
}

public protocol FASActionCreator {
}

public extension FASActionCreator {
  var dispatcher: FASFluxDispatcher {
    return FASFluxDispatcher.main
  }
  func dispatchAsync(action:Any, completion: (()->Void)? = nil) {
    DispatchQueue.main.async {
      self.dispatcher.dispatchAction(action: action)
      if completion != nil {
        completion!()
      }
    }
  }
  func dispatch(action:Any) {
    if Thread.isMainThread {
      self.dispatcher.dispatchAction(action: action)
    } else {
      DispatchQueue.main.sync {
        self.dispatcher.dispatchAction(action: action)
      }
    }
  }
}

public protocol ActionCreating { }
public extension ActionCreating {
  static var dispatcher: FASFluxDispatcher {
    return FASFluxDispatcher.main
  }
  static func dispatchAsync(action:Any, completion: (()->Void)? = nil) {
    DispatchQueue.main.async {
      self.dispatcher.dispatchAction(action: action)
      if completion != nil {
        completion!()
      }
    }
  }
  static func dispatch(action:Any) {
    if Thread.isMainThread {
      self.dispatcher.dispatchAction(action: action)
    } else {
      DispatchQueue.main.sync {
        self.dispatcher.dispatchAction(action: action)
      }
    }
  }
}
