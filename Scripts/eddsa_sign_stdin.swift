import CryptoKit
import Foundation

// Release-time EdDSA signing bridge. Cryptographically identical to the
// app's verification path (Curve25519/Ed25519 raw keys + detached sig).
//
//   swift eddsa_sign_stdin.swift <private-key-file> <payload-file>
//
// Prints the base64 Ed25519 signature over the payload's exact bytes.

func bail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

guard CommandLine.arguments.count == 3 else {
    bail("usage: swift eddsa_sign_stdin.swift <private-key-file> <payload-file>")
}

let keyPath = CommandLine.arguments[1]
let payloadPath = CommandLine.arguments[2]

guard let keyData = try? Data(contentsOf: URL(fileURLWithPath: keyPath)) else {
    bail("error: cannot read private key \(keyPath)")
}
guard let payload = try? Data(contentsOf: URL(fileURLWithPath: payloadPath)) else {
    bail("error: cannot read payload \(payloadPath)")
}

let key: Curve25519.Signing.PrivateKey
do {
    key = try Curve25519.Signing.PrivateKey(rawRepresentation: keyData)
} catch {
    bail("error: invalid private key (\(error))")
}

let signature: Data
do {
    signature = try key.signature(for: payload)
} catch {
    bail("error: signing failed (\(error))")
}
print(signature.base64EncodedString())
