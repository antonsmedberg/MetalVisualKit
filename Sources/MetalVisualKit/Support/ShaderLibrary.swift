import Metal

/// Loads the Metal library compiled from this package's `.metal` sources.
///
/// SwiftPM compiles every `.metal` file in a target into a `default.metallib`
/// inside the *package's* resource bundle — not the host app's main bundle.
/// `MTLDevice.makeDefaultLibrary()` looks in the main bundle and will not find
/// these functions, so both renderers must load through here instead.
enum ShaderLibrary {

    enum Error: Swift.Error, CustomStringConvertible {
        case libraryUnavailable(underlying: Swift.Error)
        case functionNotFound(String)

        var description: String {
            switch self {
            case .libraryUnavailable(let underlying):
                return "MetalVisualKit could not load its shader library: \(underlying)"
            case .functionNotFound(let name):
                return "MetalVisualKit shader function '\(name)' was not found in default.metallib"
            }
        }
    }

    static func make(device: MTLDevice) throws -> MTLLibrary {
        do {
            return try device.makeDefaultLibrary(bundle: .module)
        } catch {
            throw Error.libraryUnavailable(underlying: error)
        }
    }

    static func function(_ name: String, in library: MTLLibrary) throws -> MTLFunction {
        guard let function = library.makeFunction(name: name) else {
            throw Error.functionNotFound(name)
        }
        return function
    }
}
