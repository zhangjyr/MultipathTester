//
//  TCPFileDescriptorFinder.swift
//  QUICTester
//
//  Created by Quentin De Coninck on 10/18/17.
//  Copyright © 2017 Universite Catholique de Louvain. All rights reserved.
//

import Foundation

func ipsOf(hostname: String) -> [String] {
    var ips = [String]()
    let host = CFHostCreateWithName(nil, hostname as CFString).takeRetainedValue()
    CFHostStartInfoResolution(host, .addresses, nil)
    var success: DarwinBoolean = false
    if let addresses = CFHostGetAddressing(host, &success)?.takeUnretainedValue() as NSArray? {
        for case let theAddress as NSData in addresses {
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(theAddress.bytes.assumingMemoryBound(to: sockaddr.self), socklen_t(theAddress.length), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
                let numAddress = String(cString: hostname)
                ips.append(numAddress)
            }
        }
    }
    return ips
}

func findTCPFileDescriptor(expectedIPs: [String], expectedPort: Int16, exclude: Int32) -> Int32 {
    // This is quite ugly, but Apple does not provide an easy way to collect this information...
    let startFd: Int32 = 0
    let stopFd: Int32 = startFd + 1000
    // FIXME consider changing this later to adapt to changing fd
    for fd in 0...stopFd {
        //print(fd)
        if fd == exclude {
            continue
        }
        var saddr = sockaddr()
        var slen: socklen_t = socklen_t(MemoryLayout<sockaddr>.size)
        let err = getpeername(fd, &saddr, &slen)
        if err == 0 {
            //print(fd)
            let port = Int16(UInt16(UInt8(bitPattern: saddr.sa_data.0)) * 256 + UInt16(UInt8(bitPattern: saddr.sa_data.1)))
            if port != expectedPort {
                print(fd, port, expectedPort)
                continue
            }
            // In case of v6, we MUST redo the call with enough place for the IPv6 address
            if saddr.sa_family == AF_INET6 {
                var saddr_in6 = withUnsafePointer(to: &saddr) {
                    $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                        $0.pointee
                    }
                }
                var slen6: socklen_t = socklen_t(MemoryLayout<sockaddr_in6>.size)
                let err6 = withUnsafeMutablePointer(to: &saddr_in6) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        getpeername(fd, $0, &slen6)
                    }
                }
                if err6 == 0 {
                    print("Oooh... 6")
                    var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    var addr_in6 = saddr_in6
                    let gnInfo = withUnsafeMutablePointer(to: &addr_in6) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            getnameinfo($0, socklen_t(saddr_in6.sin6_len), &hostBuffer, socklen_t(hostBuffer.count), nil, 0, NI_NUMERICHOST)
                        }
                    }
                    if gnInfo == 0 {
                        let host = String(cString: hostBuffer)
                        print("FD \(fd) ip \(host) port \(port)")
                        for expIP in expectedIPs {
                            print(host, expIP)
                            if host == expIP {
                                return fd
                            }
                        }
                    }
                }
            } else {
                print("Oooh... 4")
                var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if (getnameinfo(&saddr, socklen_t(saddr.sa_len), &hostBuffer, socklen_t(hostBuffer.count), nil, 0, NI_NUMERICHOST) == 0) {
                    let host = String(cString: hostBuffer)
                    print("FD \(fd) ip \(host) port \(port)")
                    for expIP in expectedIPs {
                        print(host, expIP)
                        if host == expIP {
                            return fd
                        }
                    }
                }
            }
        }
    }
    return -1
}
