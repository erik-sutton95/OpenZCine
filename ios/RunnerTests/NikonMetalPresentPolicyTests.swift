import Metal
import MetalPerformanceShaders
import OpenCineApple
import XCTest

/// Actual source-resolution texture and native MPS comparison. SIMULATED, not hardware qualification.
final class NikonMetalPresentPolicyTests: XCTestCase {
    func testSelectedLanczosAndOffMatchOriginalNativeFitWhileSharedDefaultRemainsBilinear() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let input = try source(device: device, width: 13, height: 9)
        let native = MonitorPresentScaler(device: device)
        let off = try render(device: device, queue: queue, width: 43, height: 31) { target, command in
            XCTAssertTrue(native.encode(from: input, to: target, commandBuffer: command, overlay: false,
                options: .init(upscaler: .off, resampling: .selectedUpscaler, exactCopyAtNativeSize: true)))
        }
        let fast = try render(device: device, queue: queue, width: 43, height: 31) { target, command in
            XCTAssertTrue(native.encode(from: input, to: target, commandBuffer: command, overlay: false,
                options: .init(upscaler: .lanczos, resampling: .selectedUpscaler, exactCopyAtNativeSize: true)))
        }
        let legacyOff = try render(device: device, queue: queue, width: 43, height: 31) { target, command in
            originalFit(device: device, source: input, target: target, command: command, off: true)
        }
        let legacyFast = try render(device: device, queue: queue, width: 43, height: 31) { target, command in
            originalFit(device: device, source: input, target: target, command: command, off: false)
        }
        let unchangedDefault = try render(device: device, queue: queue, width: 43, height: 31) { target, command in
            XCTAssertTrue(native.encode(from: input, to: target, commandBuffer: command, overlay: false))
        }
        XCTAssertEqual(off, legacyOff)
        XCTAssertEqual(fast, legacyFast)
        XCTAssertEqual(unchangedDefault, legacyOff)
        XCTAssertNotEqual(fast, off, "real high-contrast pixels must exercise the selected kernel")
        XCTAssertTrue(fast.contains { $0 != 0 })
    }

    func testOriginalNativeSizeCopyPreservesEveryEncodedSourceByte() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let input = try source(device: device, width: 13, height: 9)
        let native = MonitorPresentScaler(device: device)
        let output = try render(device: device, queue: queue, width: 13, height: 9) { target, command in
            XCTAssertTrue(native.encode(from: input, to: target, commandBuffer: command, overlay: false,
                options: .init(upscaler: .lanczos, resampling: .selectedUpscaler, exactCopyAtNativeSize: true)))
        }
        XCTAssertEqual(output, bytes(input))
        XCTAssertEqual(MonitorPresentationOptions().resampling, .bilinear)
        XCTAssertFalse(MonitorPresentationOptions().exactCopyAtNativeSize)
    }

    private func source(device: MTLDevice, width: Int, height: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead]
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        var raster = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                raster[i] = x.isMultiple(of: 2) ? 20 : 210
                raster[i + 1] = y < height / 2 ? 190 : 30
                raster[i + 2] = y.isMultiple(of: 2) ? 180 : 40
                raster[i + 3] = 255
            }
        }
        raster.withUnsafeBytes {
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                withBytes: $0.baseAddress!, bytesPerRow: width * 4)
        }
        return texture
    }

    private func render(device: MTLDevice, queue: MTLCommandQueue, width: Int, height: Int,
        encode: (MTLTexture, MTLCommandBuffer) -> Void) throws -> [UInt8] {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        let target = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        encode(target, command)
        command.commit()
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed, command.error?.localizedDescription ?? "")
        return bytes(target)
    }

    private func bytes(_ texture: MTLTexture) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        output.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: texture.width * 4,
                from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        return output
    }

    /// Original native fit primitives retained independently of the new owner.
    private func originalFit(device: MTLDevice, source: MTLTexture, target: MTLTexture,
        command: MTLCommandBuffer, off: Bool) {
        let clearPass = MTLRenderPassDescriptor()
        clearPass.colorAttachments[0].texture = target
        clearPass.colorAttachments[0].loadAction = .clear
        clearPass.colorAttachments[0].storeAction = .store
        clearPass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        command.makeRenderCommandEncoder(descriptor: clearPass)?.endEncoding()
        let scale = min(
            Double(target.width) / Double(source.width),
            Double(target.height) / Double(source.height))
        var transform = MPSScaleTransform(
            scaleX: scale, scaleY: scale,
            translateX: (Double(target.width) - Double(source.width) * scale) / 2,
            translateY: (Double(target.height) - Double(source.height) * scale) / 2)
        let scaler: MPSImageScale = off ? MPSImageBilinearScale(device: device) : MPSImageLanczosScale(device: device)
        withUnsafePointer(to: &transform) { pointer in
            scaler.scaleTransform = pointer
            scaler.encode(commandBuffer: command, sourceTexture: source, destinationTexture: target)
            scaler.scaleTransform = nil
        }
    }
}
