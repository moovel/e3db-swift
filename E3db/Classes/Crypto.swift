//
//  Crypto.swift
//  E3db
//

import Foundation
import Sodium

typealias RawAccessKey       = SecretBox.Key
typealias EncryptedAccessKey = String

struct Crypto {
    typealias SecretBoxCipherNonce = (authenticatedCipherText: Data, nonce: SecretBox.Nonce)
    typealias BoxCipherNonce       = (authenticatedCipherText: Data, nonce: Box.Nonce)
    fileprivate static let sodium  = Sodium()
}

// MARK: Base64url Encoding / Decoding

extension Crypto {
    static func base64UrlEncoded(data: Data) throws -> String {
        guard let encoded = sodium.utils.bin2base64(data, variant: .URLSAFE_NO_PADDING) else {
            throw E3dbError.cryptoError("Failed to encode data")
        }
        return encoded
    }

    static func base64UrlDecoded(string: String) throws -> Data {
        guard let decoded = sodium.utils.base642bin(string, variant: .URLSAFE_NO_PADDING) else {
            throw E3dbError.cryptoError("Failed to decode data")
        }
        return decoded
    }
}

// MARK: Utilities

extension Crypto {
    static func generateKeyPair() -> Box.KeyPair? {
        return sodium.box.keyPair()
    }

    static func generateSigningKeyPair() -> Sign.KeyPair? {
        return sodium.sign.keyPair()
    }

    static func generateAccessKey() -> RawAccessKey? {
        return sodium.secretBox.key()
    }

    static func b64Join(_ ciphertexts: Data...) throws -> String {
        return try ciphertexts.map(base64UrlEncoded).joined(separator: ".")
    }

    static func b64SplitData(_ value: String) throws -> (Data, Data, Data, Data)? {
        let split = try b64Split(value)
        guard split.count == 4 else { return nil }
        return (split[0], split[1], split[2], split[3])
    }

    static func b64SplitEak(_ value: String) throws -> (Data, Data)? {
        let split = try b64Split(value)
        guard split.count == 2 else { return nil }
        return (split[0], split[1])
    }

    private static func b64Split(_ value: String) throws -> [Data] {
        return try value.components(separatedBy: ".").map(base64UrlDecoded)
    }
}

// MARK: Access Key Crypto

extension Crypto {

    static func encrypt(accessKey: RawAccessKey, readerClientKey: ClientKey, authorizerPrivKey: Box.SecretKey) -> EncryptedAccessKey? {
        return Box.PublicKey(base64UrlEncoded: readerClientKey.curve25519)
            .flatMap { sodium.box.seal(message: accessKey, recipientPublicKey: $0, senderSecretKey: authorizerPrivKey) }
            .flatMap { (eakData: BoxCipherNonce) in try? b64Join(eakData.authenticatedCipherText, eakData.nonce) }
    }

    static func decrypt(eakInfo: EAKInfo, clientPrivateKey: String) throws -> RawAccessKey {
        guard let (eak, eakN) = try b64SplitEak(eakInfo.eak) else {
            throw E3dbError.cryptoError("Invalid access key format")
        }

        guard let authorizerPubKey = Box.PublicKey(base64UrlEncoded: eakInfo.authorizerPublicKey.curve25519),
              let privKey = Box.SecretKey(base64UrlEncoded: clientPrivateKey),
              let ak = sodium.box.open(authenticatedCipherText: eak, senderPublicKey: authorizerPubKey, recipientSecretKey: privKey, nonce: eakN) else {
            throw E3dbError.cryptoError("Failed to decrypt access key")
        }

        return ak
    }
}

// MARK: Record Data Crypto

extension Crypto {

    private static func generateDataKey() throws -> SecretBox.Key {
        guard let secretKey = sodium.secretBox.key() else {
            throw E3dbError.cryptoError("Failed to generate data key")
        }
        return secretKey
    }

    private static func encrypt(value: Data?, key: SecretBox.Key) throws -> SecretBoxCipherNonce {
        guard let data = value,
              let cipher: SecretBoxCipherNonce = sodium.secretBox.seal(message: data, secretKey: key) else {
            throw E3dbError.cryptoError("Failed to encrypt value")
        }
        return cipher
    }

    static func encrypt(recordData: RecordData, ak: RawAccessKey) throws -> CipherData {
        var encrypted = CipherData()

        for (key, value) in recordData.cleartext {
            let bytes       = value.data(using: .utf8)
            let dk          = try generateDataKey()
            let (ef, efN)   = try encrypt(value: bytes, key: dk)
            let (edk, edkN) = try encrypt(value: dk, key: ak)
            encrypted[key]  = try b64Join(edk, edkN, ef, efN)
        }
        return encrypted
    }

    private static func decrypt(ciphertext: Data, nonce: SecretBox.Nonce, key: SecretBox.Key) throws -> Data {
        guard let plain = sodium.secretBox.open(authenticatedCipherText: ciphertext, secretKey: key, nonce: nonce) else {
            throw E3dbError.cryptoError("Failed to decrypt value")
        }
        return plain
    }

    static func decrypt(cipherData: CipherData, ak: RawAccessKey) throws -> RecordData {
        var decrypted = Cleartext()

        for (key, value) in cipherData {
            guard let (edk, edkN, ef, efN) = try b64SplitData(value) else {
                throw E3dbError.cryptoError("Invalid data format")
            }
            let dk    = try decrypt(ciphertext: edk, nonce: edkN, key: ak)
            let field = try decrypt(ciphertext: ef, nonce: efN, key: dk)
            decrypted[key] = String(data: field, encoding: .utf8)
        }
        return RecordData(cleartext: decrypted)
    }
}

// MARK: Document Crypto

extension Crypto {

    static func signature(doc: Signable, signingKey: Sign.SecretKey) -> String? {
        let message = Data(doc.serialized().utf8)
        return sodium.sign.signature(message: message, secretKey: signingKey)?.base64UrlEncodedString()
    }

    static func verify(doc: Signable, encodedSig: String, verifyingKey: Sign.PublicKey) -> Bool? {
        let message = Data(doc.serialized().utf8)
        return Data(base64UrlEncoded: encodedSig)
            .map { sodium.sign.verify(message: message, publicKey: verifyingKey, signature: $0) }
    }

}
