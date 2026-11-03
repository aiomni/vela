import Foundation
import Metal

/// A bounded set of writable buffers. A slot stays leased until its GPU command
/// completes, so live drawing and offscreen checks cannot overwrite in-flight data.
final class StarRingBuffers: @unchecked Sendable {
    struct Slot {
        let vertices: any MTLBuffer
        let fields: any MTLBuffer
    }
    let vertexCapacity = 1024
    private let lock = NSLock()
    private let slots: [Slot]
    private var leased = [Bool](repeating:false,count:3)

    init(device: any MTLDevice, vertexStride: Int, fieldStride: Int) throws {
        var slots: [Slot] = []
        for index in 0..<3 {
            guard let vertices = device.makeBuffer(length:vertexCapacity*vertexStride,options:.storageModeShared),
                  let fields = device.makeBuffer(length:80*fieldStride,options:.storageModeShared) else {
                throw NSError(domain:"StarRingBuffers",code:1)
            }
            vertices.label = "StarRing moving geometry \(index)"
            fields.label = "StarRing prepared lights \(index)"
            slots.append(Slot(vertices:vertices,fields:fields))
        }
        self.slots = slots
    }

    func acquire() -> (Int,Slot)? {
        lock.lock()
        defer { lock.unlock() }
        guard let index = leased.firstIndex(of:false) else { return nil }
        leased[index] = true
        return (index,slots[index])
    }

    func release(_ index: Int) {
        lock.lock()
        leased[index] = false
        lock.unlock()
    }
}
