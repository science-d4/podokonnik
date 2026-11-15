import CryptoKit
import Foundation

let publicKey = Bundle(path: CommandLine.arguments[1])?.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
let raw = ProcessInfo.processInfo.environment["SPARKLE_PRIVATE_KEY"].flatMap { Data(base64Encoded: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
guard let raw, let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw),
      key.publicKey.rawRepresentation.base64EncodedString() == publicKey else {
    fputs("Update signing key does not match the application's public key.\n", stderr)
    exit(1)
}
print("Update signing key matches the application.")
