import Foundation

struct IconRepresentation {
    let type: String
    let fileName: String
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    fatalError("Usage: MakeICNS <iconset-directory> <output.icns>")
}

let iconsetURL = URL(fileURLWithPath: arguments[1], isDirectory: true)
let outputURL = URL(fileURLWithPath: arguments[2])
let representations = [
    IconRepresentation(type: "icp4", fileName: "icon_16x16.png"),
    IconRepresentation(type: "icp5", fileName: "icon_32x32.png"),
    IconRepresentation(type: "icp6", fileName: "icon_32x32@2x.png"),
    IconRepresentation(type: "ic07", fileName: "icon_128x128.png"),
    IconRepresentation(type: "ic08", fileName: "icon_256x256.png"),
    IconRepresentation(type: "ic09", fileName: "icon_512x512.png"),
    IconRepresentation(type: "ic10", fileName: "icon_512x512@2x.png"),
    IconRepresentation(type: "ic11", fileName: "icon_16x16@2x.png"),
    IconRepresentation(type: "ic12", fileName: "icon_32x32@2x.png"),
    IconRepresentation(type: "ic13", fileName: "icon_128x128@2x.png"),
    IconRepresentation(type: "ic14", fileName: "icon_256x256@2x.png")
]

func appendBigEndian(_ value: UInt32, to data: inout Data) {
    var bigEndianValue = value.bigEndian
    withUnsafeBytes(of: &bigEndianValue) { bytes in
        data.append(contentsOf: bytes)
    }
}

var chunks = Data()
for representation in representations {
    let imageData = try Data(contentsOf: iconsetURL.appendingPathComponent(representation.fileName))
    guard let typeData = representation.type.data(using: .ascii), typeData.count == 4 else {
        fatalError("Invalid ICNS type \(representation.type)")
    }
    chunks.append(typeData)
    appendBigEndian(UInt32(imageData.count + 8), to: &chunks)
    chunks.append(imageData)
}

var output = Data("icns".utf8)
appendBigEndian(UInt32(chunks.count + 8), to: &output)
output.append(chunks)
try output.write(to: outputURL, options: .atomic)
print("Wrote \(output.count) bytes to \(outputURL.path)")
