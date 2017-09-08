//
//  Utils.swift
//  E3db
//

import Foundation
import Sodium
import Result
import Argo
import Swish
import Heimdallr

/// Possible errors encountered from E3db operations
public enum E3dbError: Swift.Error {

    /// A crypto operation failed (`message`)
    case cryptoError(String)

    /// Configuration failed (`message`)
    case configError(String)

    /// A network operation failed (`message`)
    case networkError(String)

    /// JSON parsing failed (`expected`, `actual`)
    case jsonError(String, String)

    /// An API request encountered an error (`statusCode`, `message`)
    case apiError(Int, String)

    internal init(swishError: SwishError) {
        switch swishError {
        case .argoError(.typeMismatch(let exp, let act)):
            self = .jsonError("Expected: \(exp). ", "Actual: \(act).")
        case .argoError(.missingKey(let key)):
            self = .jsonError("Expected: \(key). ", "Actual: (key not found).")
        case .argoError(let err):
            self = .jsonError("", err.description)
        case .serverError(let code, data: _) where code == 401 || code == 403:
            self = .apiError(code, "Unauthorized")
        case .serverError(code: 404, data: _):
            self = .apiError(404, "Requested item not found")
        case .serverError(code: 409, data: _):
            self = .apiError(409, "Existing item cannot be modified")
        case .serverError(code: let code, data: _):
            self = .apiError(code, swishError.errorDescription ?? "Failed request")
        case .deserializationError, .parseError, .urlSessionError:
            self = .networkError(swishError.errorDescription ?? "Failed request")
        }
    }

    /// Get a readable context for the error.
    ///
    /// - Returns: A human-readable description for the error
    public func description() -> String {
        switch self {
        case .cryptoError(let msg), .configError(let msg), .networkError(let msg):
            return msg
        case let .jsonError(exp, act):
            return "Failed to decode response. \(exp + act)"
        case let .apiError(code, msg):
            return "API Error (\(code)): \(msg)"
        }
    }
}

struct Api {
    static let defaultUrl   = "https://api.e3db.com/"
    private let version     = "v1"
    private let pdsService  = "storage"
    private let authService = "auth"
    private let acctService = "account"

    let baseUrl: URL
    let tokenUrl: URL
    let registerUrl: URL

    init(baseUrl: URL) {
        self.baseUrl = baseUrl
        self.tokenUrl = baseUrl / version / authService / "token"
        self.registerUrl = baseUrl / version / acctService / "e3db" / "clients" / "register"
    }

    func url(endpoint: Endpoint) -> URL {
        return baseUrl / version / pdsService / endpoint.rawValue
    }
}

enum Endpoint: String {
    case records
    case clients
    case accessKeys = "access_keys"
    case search
    case policy
}

struct AkCacheKey: Hashable {
    let recordType: String
    let writerId: UUID
    let readerId: UUID

    var hashValue: Int {
        return [writerId, readerId]
            .map { $0.uuidString }
            .reduce(recordType, +)
            .hashValue
    }

    static func == (lhs: AkCacheKey, rhs: AkCacheKey) -> Bool {
        return lhs.recordType == rhs.recordType &&
            lhs.writerId == rhs.writerId &&
            lhs.readerId == rhs.readerId
    }
}

struct AuthedRequestPerformer {
    let session: URLSession
    let authenticator: Heimdallr

    init(authenticator: Heimdallr, session: URLSession = .shared) {
        self.session = session
        self.authenticator = authenticator
    }
}

extension AuthedRequestPerformer: RequestPerformer {
    typealias ResponseHandler = (Result<HTTPResponse, SwishError>) -> Void

    @discardableResult
    internal func perform(_ request: URLRequest, completionHandler: @escaping ResponseHandler) -> URLSessionDataTask {
        if authenticator.hasAccessToken {
            authenticator.authenticateRequest(request) { (result) in
                if case .success(let req) = result {
                    self.perform(authedRequest: req, completionHandler: completionHandler)
                } else {
                    // Authentication failed, clearing token to retry...
                    self.authenticator.clearAccessToken()
                    self.perform(request, completionHandler: completionHandler)
                }
            }
        } else {
            // No token found, requesting auth token...
            requestAccessToken(request, completionHandler: completionHandler)
        }

        // unused, artifact of Swish
        return URLSessionDataTask()
    }

    private func requestAccessToken(_ request: URLRequest, completionHandler: @escaping ResponseHandler) {
        authenticator.requestAccessToken(grantType: "client_credentials", parameters: ["grant_type": "client_credentials"]) { (result) in
            guard case .success = result else {
                // Failed to request token
                return completionHandler(.failure(.serverError(code: 401, data: nil)))
            }

            // Got token, authenticating request...
            self.authenticateRequest(request, completionHandler: completionHandler)
        }
    }

    private func authenticateRequest(_ request: URLRequest, completionHandler: @escaping ResponseHandler) {
        authenticator.authenticateRequest(request) { (result) in
            guard case .success(let req) = result else {
                // Failed to authenticate request
                return completionHandler(.failure(.serverError(code: 422, data: nil)))
            }

            // Added auth to the request, now performing it...
            self.perform(authedRequest: req, completionHandler: completionHandler)
        }
    }

    private func perform(authedRequest: URLRequest, completionHandler: @escaping ResponseHandler) {
        // Must capitalize "Bearer" since the Heimdallr lib chooses
        // to use exactly what is returned from the token request.
        // https://github.com/trivago/Heimdallr.swift/pull/59
        //
        // RFC 6749 suggests that the token type is case insensitive,
        // https://tools.ietf.org/html/rfc6749#section-5.1 while
        // RFC 6750 suggests the Authorization header with "Bearer" prefix
        // is capitalized, https://tools.ietf.org/html/rfc6750#section-2.1
        // ¯\_(ツ)_/¯
        var req  = authedRequest
        let auth = req.allHTTPHeaderFields?["Authorization"]?.replacingOccurrences(of: "bearer", with: "Bearer")
        req.setValue(auth, forHTTPHeaderField: "Authorization")

        let task = self.session.dataTask(with: req) { data, response, error in
            if let error = error {
                completionHandler(.failure(.urlSessionError(error)))
            } else {
                let resp = HTTPResponse(data: data, response: response)
                completionHandler(.success(resp))
            }
        }
        task.resume()
    }
}