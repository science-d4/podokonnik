import CryptoKit
import Foundation
let path = CommandLine.arguments[1]
let publicPath = CommandLine.arguments[2]
let url = URL(fileURLWithPath: path)
guard !FileManager.default.fileExists(atPath: path) else { fatalError("Update key already exists; it will not be replaced") }
let key = Curve25519.Signing.PrivateKey()
let data = Data((key.rawRepresentation.base64EncodedString() + "\n").utf8)
guard FileManager.default.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600]) else { fatalError("Could not save update key") }
try Data((key.publicKey.rawRepresentation.base64EncodedString() + "\n").utf8).write(to: URL(fileURLWithPath: publicPath), options: .atomic)
print("Test signing key generated")
