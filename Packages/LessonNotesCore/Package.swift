// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "LessonNotesCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LessonNotesCore", targets: ["LessonNotesCore"]),
    ],
    targets: [
        .target(name: "LessonNotesCore"),
        .testTarget(name: "LessonNotesCoreTests", dependencies: ["LessonNotesCore"]),
    ]
)
