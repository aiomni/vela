import Metal

/// A deterministic scalar/vector field, generated once. This contains no design
/// imagery; the shader samples it at live, moving three-dimensional coordinates.
enum MaterialVolume {
    static func make(device: any MTLDevice,queue: any MTLCommandQueue) throws -> any MTLTexture {
        let side = 64
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D;descriptor.pixelFormat = .rgba8Unorm
        descriptor.width = side;descriptor.height = side;descriptor.depth = side
        descriptor.mipmapLevelCount = 7;descriptor.storageMode = .shared;descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor:descriptor),let command = queue.makeCommandBuffer(),
              let blit = command.makeBlitCommandEncoder() else { throw NSError(domain:"MaterialVolume",code:1) }
        texture.label = "Reusable procedural material volume"
        var bytes = [UInt8](repeating:0,count:side*side*side*4)
        for voxel in 0..<(side*side*side) { for channel in 0..<4 {
            var seed = UInt32(voxel) ^ (UInt32(channel+1) &* 0x9e3779b9)
            seed = (seed ^ (seed >> 16)) &* 0x7feb352d
            seed = (seed ^ (seed >> 15)) &* 0x846ca68b
            seed ^= seed >> 16
            bytes[voxel*4+channel] = UInt8(truncatingIfNeeded:seed >> 24)
        }}
        bytes.withUnsafeBytes {
            texture.replace(region:MTLRegionMake3D(0,0,0,side,side,side),mipmapLevel:0,slice:0,withBytes:$0.baseAddress!,
                bytesPerRow:side*4,bytesPerImage:side*side*4)
        }
        blit.generateMipmaps(for:texture);blit.endEncoding()
        command.commit();command.waitUntilCompleted()
        guard command.status == .completed else { throw command.error ?? NSError(domain:"MaterialVolume",code:2) }
        return texture
    }
}
