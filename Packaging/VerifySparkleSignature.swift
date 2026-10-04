import CryptoKit
import Foundation

let arguments = CommandLine.arguments
if arguments.count != 4 {
    fputs("Expected public key, file, and signature.\n", stderr)
    exit(2)
}
guard let publicData = Data(base64Encoded: arguments[1]), publicData.count == 32,
      let signature = Data(base64Encoded: arguments[3]), signature.count == 64 else {
    fputs("Invalid Ed25519 verification metadata.\n", stderr)
    exit(1)
}
let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicData)
let data = try Data(contentsOf: URL(fileURLWithPath: arguments[2]), options: .mappedIfSafe)
if !key.isValidSignature(signature, for: data) {
    fputs("Sparkle signature verification failed.\n", stderr)
    exit(1)
}
