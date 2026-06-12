// SecurityHandler.swift — Motosync Bridge
// Native Swift Cryptography for Honda BTU GATT Handshake

import Foundation
import CommonCrypto
import Security

// MARK: — Checksum (CRC-16 IBM/Modbus)
// Table-based 16-bit CRC matching the decompiled Checksum.java class.
enum Checksum {
    static let table: [UInt16] = [
        0, 49345, 49537, 320, 49921, 960, 640, 49729, 50689, 1728, 1920, 51009, 1280, 50625, 50305, 1088,
        52225, 3264, 3456, 52545, 3840, 53185, 52865, 3648, 2560, 51905, 52097, 2880, 51457, 2496,
        2176, 51265, 55297, 6336, 6528, 55617, 6912, 56257, 55937, 6720, 7680, 57025, 57217, 8000,
        56577, 7616, 7296, 56385, 5120, 54465, 54657, 5440, 55041, 6080, 5760, 54849, 53761, 4800,
        4992, 54081, 4352, 53697, 53377, 4160, 61441, 12480, 12672, 61761, 13056, 62401, 62081, 12864,
        13824, 63169, 63361, 14144, 62721, 13760, 13440, 62529, 15360, 64705, 64897, 15680, 65281, 16320,
        16000, 65089, 64001, 15040, 15232, 64321, 14592, 63937, 63617, 14400, 10240, 59585, 59777, 10560,
        60161, 11200, 10880, 59969, 60929, 11968, 12160, 61249, 11520, 60865, 60545, 11328, 58369, 9408,
        9600, 58689, 9984, 59329, 59009, 9792, 8704, 58049, 58241, 9024, 57601, 8640, 8320, 57409,
        40961, 24768, 24960, 41281, 25344, 41921, 41601, 25152, 26112, 42689, 42881, 26432, 42241, 26048,
        25728, 42049, 27648, 44225, 44417, 27968, 44801, 28608, 28288, 44609, 43521, 27328, 27520, 43841,
        26880, 43457, 43137, 26688, 30720, 47297, 47489, 31040, 47873, 31680, 31360, 47681, 48641, 32448,
        32640, 48961, 32000, 48577, 48257, 31808, 46081, 29888, 30080, 46401, 30464, 47041, 46721, 30272,
        29184, 45761, 45953, 29504, 45313, 29120, 28800, 45121, 20480, 37057, 37249, 20800, 37633, 21440,
        21120, 37441, 38401, 22208, 22400, 38721, 21760, 38337, 38017, 21568, 39937, 23744, 23936, 40257,
        24320, 40897, 40577, 24128, 23040, 39617, 39809, 23360, 39169, 22976, 22656, 38977, 34817, 18624,
        18816, 35137, 19200, 35777, 35457, 19008, 19968, 36545, 36737, 20288, 36097, 19904, 19584, 35905,
        17408, 33985, 34177, 17728, 34561, 18368, 18048, 34369, 33281, 17088, 17280, 33601, 16640, 33217,
        32897, 16448
    ]

    static func calculate(for data: Data) -> UInt16 {
        var crc: UInt16 = 0
        for byte in data {
            let index = Int((crc ^ UInt16(byte)) & 0xFF)
            crc = table[index] ^ (crc >> 8)
        }
        return crc
    }

    static func calculateBytes(for data: Data) -> Data {
        let crc = calculate(for: data)
        return Data([UInt8(crc & 0xFF), UInt8((crc >> 8) & 0xFF)])
    }
}

// MARK: — AES Cryptor (128-bit ECB Mode)
enum AESCryptor {
    static func encryptECB_PKCS7(data: Data, key: Data) -> Data? {
        return crypt(data: data, key: key, operation: CCOperation(kCCEncrypt), options: CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode))
    }
    
    static func decryptECB_PKCS7(data: Data, key: Data) -> Data? {
        return crypt(data: data, key: key, operation: CCOperation(kCCDecrypt), options: CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode))
    }
    
    static func decryptECB_NoPadding(data: Data, key: Data) -> Data? {
        return crypt(data: data, key: key, operation: CCOperation(kCCDecrypt), options: CCOptions(kCCOptionECBMode))
    }
    
    private static func crypt(data: Data, key: Data, operation: CCOperation, options: CCOptions) -> Data? {
        guard key.count == kCCKeySizeAES128 else { return nil }
        
        let dataOutLength = data.count + kCCBlockSizeAES128
        var dataOut = Data(count: dataOutLength)
        var numBytesCrypted: Int = 0
        
        let cryptStatus = dataOut.withUnsafeMutableBytes { dataOutBytes in
            data.withUnsafeBytes { dataBytes in
                key.withUnsafeBytes { keyBytes in
                    CCCrypt(
                        operation,
                        CCAlgorithm(kCCAlgorithmAES),
                        options,
                        keyBytes.baseAddress,
                        key.count,
                        nil, // No IV for ECB
                        dataBytes.baseAddress,
                        data.count,
                        dataOutBytes.baseAddress,
                        dataOutLength,
                        &numBytesCrypted
                    )
                }
            }
        }
        
        if cryptStatus == kCCSuccess {
            dataOut.removeSubrange(numBytesCrypted..<dataOut.count)
            return dataOut
        } else {
            return nil
        }
    }
}

// MARK: — RSA KeyPair & Modulus Helper
struct RSAKeyPair {
    let privateKey: SecKey
    let publicKey: SecKey
    let modulus: Data
    
    static func generate(keySize: Int = 1024) -> RSAKeyPair? {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: keySize
        ]
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error),
              let publicKey = SecKeyCopyPublicKey(privateKey) else {
            print("⚠️ SecKeyCreateRandomKey failed: \(error?.takeRetainedValue().localizedDescription ?? "unknown error")")
            return nil
        }
        
        guard let externalRepresentation = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            print("⚠️ SecKeyCopyExternalRepresentation failed")
            return nil
        }
        
        guard let modulus = extractRSAModulus(from: externalRepresentation) else {
            print("⚠️ Failed to parse RSA Modulus from public key representation")
            return nil
        }
        
        return RSAKeyPair(privateKey: privateKey, publicKey: publicKey, modulus: modulus)
    }
    
    // Decrypt data with RSA/ECB/NoPadding using SecKeyCreateDecryptedData
    func decryptNoPadding(data: Data) -> Data? {
        var error: Unmanaged<CFError>?
        guard let decrypted = SecKeyCreateDecryptedData(privateKey, .rsaEncryptionRaw, data as CFData, &error) as Data? else {
            print("⚠️ SecKeyCreateDecryptedData error: \(error?.takeRetainedValue().localizedDescription ?? "unknown")")
            return nil
        }
        return decrypted
    }
    
    private static func extractRSAModulus(from pkcs1Data: Data) -> Data? {
        var index = 0
        guard pkcs1Data.count > index, pkcs1Data[index] == 0x30 else { return nil }
        index += 1
        
        // Parse SEQUENCE length
        guard index < pkcs1Data.count else { return nil }
        let seqLenByte = pkcs1Data[index]
        index += 1
        if seqLenByte & 0x80 != 0 {
            let numLenBytes = Int(seqLenByte & 0x7F)
            index += numLenBytes
        }
        
        // Next tag must be INTEGER (0x02)
        guard index < pkcs1Data.count, pkcs1Data[index] == 0x02 else { return nil }
        index += 1
        
        // Parse Modulus length
        guard index < pkcs1Data.count else { return nil }
        let modLenByte = pkcs1Data[index]
        index += 1
        var modulusLength = 0
        if modLenByte & 0x80 != 0 {
            let numLenBytes = Int(modLenByte & 0x7F)
            guard index + numLenBytes <= pkcs1Data.count else { return nil }
            for _ in 0..<numLenBytes {
                modulusLength = (modulusLength << 8) | Int(pkcs1Data[index])
                index += 1
            }
        } else {
            modulusLength = Int(modLenByte)
        }
        
        guard index + modulusLength <= pkcs1Data.count else { return nil }
        var modulusData = pkcs1Data.subdata(in: index..<(index + modulusLength))
        
        // Strip leading 0x00 byte if present (BigInteger formatting)
        if modulusData.first == 0x00 {
            modulusData = modulusData.dropFirst()
        }
        
        return modulusData
    }
}
