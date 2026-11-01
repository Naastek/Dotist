import CryptoKit
import Foundation

let key = Curve25519.Signing.PrivateKey()
let destination = URL(fileURLWithPath: CommandLine.arguments[1])
try Data(key.rawRepresentation.base64EncodedString().utf8).write(to: destination, options: .atomic)
try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
try Data(key.publicKey.rawRepresentation.base64EncodedString().utf8).write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
