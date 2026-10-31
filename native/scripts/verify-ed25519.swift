import CryptoKit
import Foundation

let key = try Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: CommandLine.arguments[1])!)
let signature = Data(base64Encoded: CommandLine.arguments[2])!
let archive = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]), options: .mappedIfSafe)
guard key.isValidSignature(signature, for: archive) else {
    fputs("Invalid native update signature\n", stderr)
    exit(1)
}
print("Native update Ed25519 signature verified")
