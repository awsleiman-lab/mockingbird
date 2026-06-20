import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let resources = root.appendingPathComponent("AppBundle/Contents/Resources")
let source = resources.appendingPathComponent("MockingbirdIconSource.png")
let iconset = resources.appendingPathComponent("Mockingbird.iconset")

let icns = resources.appendingPathComponent("Mockingbird.icns")

let outputs: [(filename: String, size: CGFloat, icnsType: String)] = [
    ("icon_16x16.png", 16, "icp4"),
    ("icon_16x16@2x.png", 32, "ic11"),
    ("icon_32x32.png", 32, "icp5"),
    ("icon_32x32@2x.png", 64, "ic12"),
    ("icon_128x128.png", 128, "ic07"),
    ("icon_128x128@2x.png", 256, "ic13"),
    ("icon_256x256.png", 256, "ic08"),
    ("icon_256x256@2x.png", 512, "ic14"),
    ("icon_512x512.png", 512, "ic09"),
    ("icon_512x512@2x.png", 1024, "ic10")
]

guard FileManager.default.fileExists(atPath: source.path) else {
    throw NSError(
        domain: "MockingbirdIcon",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Missing icon source at \(source.path)"]
    )
}

try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func resizeSource(to size: Int, at url: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
    process.arguments = [
        "-z", "\(size)", "\(size)",
        source.path,
        "--out", url.path
    ]
    process.standardOutput = Pipe()
    process.standardError = Pipe()

    try process.run()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
        throw NSError(
            domain: "MockingbirdIcon",
            code: Int(process.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: "Could not render icon size \(size)."]
        )
    }
}

func appendFourCharacterCode(_ code: String, to data: inout Data) {
    precondition(code.utf8.count == 4)
    data.append(contentsOf: code.utf8)
}

func appendBigEndianUInt32(_ value: UInt32, to data: inout Data) {
    var bigEndian = value.bigEndian
    withUnsafeBytes(of: &bigEndian) { bytes in
        data.append(contentsOf: bytes)
    }
}

func writeICNS(_ entries: [(type: String, data: Data)], to url: URL) throws {
    var iconData = Data()
    let totalLength = entries.reduce(UInt32(8)) { length, entry in
        length + UInt32(8 + entry.data.count)
    }

    appendFourCharacterCode("icns", to: &iconData)
    appendBigEndianUInt32(totalLength, to: &iconData)

    for entry in entries {
        appendFourCharacterCode(entry.type, to: &iconData)
        appendBigEndianUInt32(UInt32(8 + entry.data.count), to: &iconData)
        iconData.append(entry.data)
    }

    try iconData.write(to: url)
}

var icnsEntries: [(type: String, data: Data)] = []
for output in outputs {
    let outputURL = iconset.appendingPathComponent(output.filename)
    try resizeSource(to: Int(output.size), at: outputURL)
    let data = try Data(contentsOf: outputURL)
    icnsEntries.append((type: output.icnsType, data: data))
}

try writeICNS(icnsEntries, to: icns)
