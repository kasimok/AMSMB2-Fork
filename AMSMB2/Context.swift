//
//  Context.swift
//  AMSMB2
//
//  Created by Amir Abbas Mousavian.
//  Copyright © 2018 Mousavian. Distributed under MIT license.
//

import Foundation
import SMB2
import SMB2.Raw

final class SMB2Context {
    struct NegotiateSigning: OptionSet {
        var rawValue: UInt16
        
        static let enabled = NegotiateSigning(rawValue: UInt16(SMB2_NEGOTIATE_SIGNING_ENABLED))
        static let required = NegotiateSigning(rawValue: UInt16(SMB2_NEGOTIATE_SIGNING_REQUIRED))
    }
    
    internal var context: UnsafeMutablePointer<smb2_context>
    private var _context_lock = NSLock()
    var isConnected = false
    
    init() throws {
        guard let _context = smb2_init_context() else {
            throw POSIXError(.ENOMEM)
        }
        self.context = _context
    }
    
    deinit {
        if isConnected {
            try? self.disconnect()
        }
        withThreadSafeContext { (context) in
            smb2_destroy_context(context)
        }
    }
    
    internal func withThreadSafeContext<R>(_ handler: (UnsafeMutablePointer<smb2_context>) throws -> R) rethrows -> R {
        _context_lock.lock()
        defer {
            _context_lock.unlock()
        }
        return try handler(self.context)
    }
}

// MARK: Setting manipulation
extension SMB2Context {
    func set(workstation value: String) {
        withThreadSafeContext { (context) in
            smb2_set_workstation(context, value)
        }
    }
    
    func set(domain value: String) {
        withThreadSafeContext { (context) in
            smb2_set_domain(context, value)
        }
    }
    
    func set(user value: String) {
        withThreadSafeContext { (context) in
            smb2_set_user(context, value)
        }
    }
    
    func set(password value: String) {
        withThreadSafeContext { (context) in
            smb2_set_password(context, value)
        }
    }
    
    func set(securityMode: NegotiateSigning) {
        withThreadSafeContext { (context) in
            smb2_set_security_mode(context, securityMode.rawValue)
        }
    }
    
    func parseUrl(_ url: String) throws -> UnsafeMutablePointer<smb2_url> {
        return try withThreadSafeContext { (context) in
            if let result = smb2_parse_url(context, url) {
                return result
            }
            
            let errorDescription = self.error
            switch errorDescription {
            case "URL does not start with 'smb://'":
                throw POSIXError(.ENOPROTOOPT, description: errorDescription)
            case "URL is too long":
                throw POSIXError(.EOVERFLOW, description: errorDescription)
            case "Failed to allocate smb2_url":
                throw POSIXError(.ENOMEM, description: errorDescription)
            default:
                throw POSIXError(.EINVAL, description: errorDescription)
            }
        }
    }
    
    var clientGuid: UUID? {
        guard let guid = smb2_get_client_guid(context) else {
            return nil
        }
        
        let uuid = guid.withMemoryRebound(to: uuid_t.self, capacity: 1) { ptr in
            return ptr.pointee
        }
        
        return UUID.init(uuid: uuid)
    }
    
    var fileDescriptor: Int32 {
        return smb2_get_fd(context)
    }
    
    var error: String? {
        let errorStr = smb2_get_error(context)
        return errorStr.flatMap(String.init(utf8String:))
    }
    
    func whichEvents() -> Int32 {
        return smb2_which_events(context)
    }
    
    func service(revents: Int32) throws {
        let result = withThreadSafeContext { (context)  in
            return smb2_service(context, revents)
        }
        try POSIXError.throwIfError(result, description: error, default: .EINVAL)
    }
}

// MARK: Connectivity
extension SMB2Context {
    func connect(server: String, share: String, user: String) throws {
        try async_wait(defaultError: .ECONNREFUSED) { (context, cbPtr) -> Int32 in
            smb2_connect_share_async(context, server, share, user, SMB2Context.async_handler, cbPtr)
        }
        self.isConnected = true
    }
    
    func disconnect() throws {
        try async_wait(defaultError: .ECONNREFUSED) { (context, cbPtr) -> Int32 in
            smb2_disconnect_share_async(context, SMB2Context.async_handler, cbPtr)
        }
        self.isConnected = false
    }
    
    @discardableResult
    func echo() throws -> Bool {
        try async_wait(defaultError: .ECONNREFUSED) { (context, cbPtr) -> Int32 in
            smb2_echo_async(context, SMB2Context.async_handler, cbPtr)
        }
        return true
    }
}

// MARK: DCE-RPC
extension SMB2Context {
    func shareEnum() throws -> [(name: String, type: UInt32, comment: String)] {
        let (_, cmddata) = try async_wait(defaultError: .ENOLINK) { (context, cbPtr) -> Int32 in
            smb2_share_enum_async(context, SMB2Context.async_handler, cbPtr)
        }
        
        guard let opaque = OpaquePointer(cmddata) else {
            throw POSIXError(.ENOENT)
        }
        
        let rep = UnsafeMutablePointer<srvsvc_netshareenumall_rep>(opaque)
        defer {
            smb2_free_data(context, rep)
        }
        
        var result = [(name: String, type: UInt32, comment: String)]()
        let array = Array(UnsafeBufferPointer(start: rep.pointee.ctr.pointee.ctr1.array, count: Int(rep.pointee.ctr.pointee.ctr1.count)))
        for item in array {
            let name = String(cString: item.name)
            let type = item.type
            let comment = String(cString: item.comment)
            result.append((name: name, type: type, comment: comment))
        }
        
        return result
    }
}

// MARK: File manipulation
extension SMB2Context {
    func stat(_ path: String) throws -> smb2_stat_64 {
        let cannonicalPath = path.replacingOccurrences(of: "/", with: "\\")
        var st = smb2_stat_64()
        try async_wait(defaultError: .ENOLINK) { (context, cbPtr) -> Int32 in
            smb2_stat_async(context, cannonicalPath, &st, SMB2Context.async_handler, cbPtr)
        }
        return st
    }
    
    func statvfs(_ path: String) throws -> smb2_statvfs {
        let cannonicalPath = path.replacingOccurrences(of: "/", with: "\\")
        var st = smb2_statvfs()
        try async_wait(defaultError: .ENOLINK) { (context, cbPtr) -> Int32 in
            smb2_statvfs_async(context, cannonicalPath, &st, SMB2Context.async_handler, cbPtr)
        }
        return st
    }
    
    func truncate(_ path: String, toLength: UInt64) throws {
        let cannonicalPath = path.replacingOccurrences(of: "/", with: "\\")
        try async_wait(defaultError: .ENOLINK) { (context, cbPtr) -> Int32 in
            smb2_truncate_async(context, cannonicalPath, toLength, SMB2Context.async_handler, cbPtr)
        }
    }
}

// MARK: File operation
extension SMB2Context {
    func mkdir(_ path: String) throws {
        let cannonicalPath = path.replacingOccurrences(of: "/", with: "\\")
        try async_wait(defaultError: .EEXIST) { (context, cbPtr) -> Int32 in
            smb2_mkdir_async(context, cannonicalPath, SMB2Context.async_handler, cbPtr)
        }
    }
    
    func rmdir(_ path: String) throws {
        let cannonicalPath = path.replacingOccurrences(of: "/", with: "\\")
        try async_wait(defaultError: .ENOLINK) { (context, cbPtr) -> Int32 in
            smb2_rmdir_async(context, cannonicalPath, SMB2Context.async_handler, cbPtr)
        }
    }
    
    func unlink(_ path: String) throws {
        let cannonicalPath = path.replacingOccurrences(of: "/", with: "\\")
        try async_wait(defaultError: .ENOLINK) { (context, cbPtr) -> Int32 in
            smb2_unlink_async(context, cannonicalPath, SMB2Context.async_handler, cbPtr)
        }
    }
    
    func rename(_ path: String, to newPath: String) throws {
        let cannonicalPath = path.replacingOccurrences(of: "/", with: "\\")
        let cannonicalNewPath = path.replacingOccurrences(of: "/", with: "\\")
        try async_wait(defaultError: .ENOENT) { (context, cbPtr) -> Int32 in
            smb2_rename_async(context, cannonicalPath, cannonicalNewPath, SMB2Context.async_handler, cbPtr)
        }
    }
}

// MARK: Async operation handler
extension SMB2Context {
    private struct CBData {
        var result: Int32 = 0
        var isFinished: Bool = false
        var commandData: UnsafeMutableRawPointer? = nil
        
        static var memSize: Int {
            return MemoryLayout<CBData>.size
        }
        
        static var memAlign: Int {
            return MemoryLayout<CBData>.alignment
        }
        
        static func initPointer() -> UnsafeMutableRawPointer {
            let cbPtr = UnsafeMutableRawPointer.allocate(byteCount: CBData.memSize, alignment: CBData.memAlign)
            cbPtr.initializeMemory(as: CBData.self, repeating: .init(), count: 1)
            return cbPtr
        }
    }
    
    private func wait_for_reply(_ cbPtr: UnsafeMutableRawPointer) throws {
        while !cbPtr.bindMemory(to: CBData.self, capacity: 1).pointee.isFinished {
            var pfd = pollfd()
            pfd.fd = fileDescriptor
            pfd.events = Int16(whichEvents())
            
            if poll(&pfd, 1, 1000) < 0 {
                try POSIXError.throwIfError(errno, description: error, default: .EINVAL)
            }
            
            if pfd.revents == 0 {
                continue
            }
            
            try service(revents: Int32(pfd.revents))
        }
    }
    
    static let async_handler: @convention(c) (_ smb2: UnsafeMutablePointer<smb2_context>?, _ status: Int32, _ command_data: UnsafeMutableRawPointer?, _ cbdata: UnsafeMutableRawPointer?) -> Void = { smb2, status, command_data, cbdata in
        cbdata?.bindMemory(to: CBData.self, capacity: 1).pointee.result = status
        cbdata?.bindMemory(to: CBData.self, capacity: 1).pointee.isFinished = true
        cbdata?.bindMemory(to: CBData.self, capacity: 1).pointee.commandData = command_data
    }
    
    @discardableResult
    func async_wait(defaultError: POSIXError.Code, execute handler: (_ context: UnsafeMutablePointer<smb2_context>, _ cbPtr: UnsafeMutableRawPointer) -> Int32) throws -> (result: Int32, data: UnsafeMutableRawPointer?) {
        let cbPtr = CBData.initPointer()
        defer {
            cbPtr.deallocate()
        }
        
        let result = withThreadSafeContext { (context) -> Int32 in
            return handler(context, cbPtr)
        }
        try POSIXError.throwIfError(result, description: error, default: .ECONNRESET)
        try wait_for_reply(cbPtr)
        let cbresult = cbPtr.bindMemory(to: CBData.self, capacity: 1).pointee.result
        try POSIXError.throwIfError(cbresult, description: error, default: defaultError)
        let data = cbPtr.bindMemory(to: CBData.self, capacity: 1).pointee.commandData
        return (cbresult, data)
    }
}
