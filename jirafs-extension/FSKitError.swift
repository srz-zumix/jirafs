import Foundation
import FSKit
import JiraAPI
import JiraFSCore

/// Maps `JiraAPIError` and other Swift errors to POSIX-flavoured errors that
/// FSKit returns to the kernel.
@available(macOS 15.4, *)
enum FSKitError {
    static func from(_ error: Error) -> NSError {
        if let api = error as? JiraAPIError {
            return mapAPIError(api)
        }
        return NSError(domain: NSPOSIXErrorDomain, code: Int(POSIXError.EIO.rawValue))
    }

    private static func mapAPIError(_ error: JiraAPIError) -> NSError {
        let code: Int32 = {
            switch error {
            case .invalidURL: return POSIXError.EINVAL.rawValue
            case .unauthorized, .forbidden, .missingCredentials: return POSIXError.EACCES.rawValue
            case .notFound: return POSIXError.ENOENT.rawValue
            case .rateLimited: return POSIXError.EAGAIN.rawValue
            case .serverError, .transport, .decoding: return POSIXError.EIO.rawValue
            case .unsupported: return POSIXError.ENOTSUP.rawValue
            }
        }()
        return NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }

    static let notSupported = NSError(domain: NSPOSIXErrorDomain, code: Int(POSIXError.ENOTSUP.rawValue))
    static let notFound = NSError(domain: NSPOSIXErrorDomain, code: Int(POSIXError.ENOENT.rawValue))
    static let readOnly = NSError(domain: NSPOSIXErrorDomain, code: Int(POSIXError.EROFS.rawValue))
}
