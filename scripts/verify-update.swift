// Verifies an update archive's EdDSA signature against a public key, independently of Sparkle's
// tools and of the private key. Usage: swift scripts/verify-update.swift FILE SIGNATURE PUBLIC_KEY
import CryptoKit
import Foundation

let args = CommandLine.arguments
guard args.count == 4,
      let data = FileManager.default.contents(atPath: args[1]),
      let sig = Data(base64Encoded: args[2]),
      let raw = Data(base64Encoded: args[3]),
      let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
else {
    FileHandle.standardError.write("usage: verify-update.swift FILE SIGNATURE PUBLIC_KEY\n".data(using: .utf8)!)
    exit(2)
}
if key.isValidSignature(sig, for: data) {
    print("EdDSA signature valid for \(args[1])")
} else {
    FileHandle.standardError.write("EdDSA signature INVALID for \(args[1])\n".data(using: .utf8)!)
    exit(1)
}
