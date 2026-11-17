// swift-tools-version: 5.9

// Paquete de app para Swift Playgrounds (iPad) o Xcode (Mac).
// AVISO: este manifiesto no pudo validarse en el entorno donde se escribió (Linux, sin toolchain de Apple).
// Si Swift Playgrounds o Xcode lo rechazan, crea un proyecto "App" nuevo y copia los demás archivos .swift.

import PackageDescription
import AppleProductTypes

let package = Package(
    name: "VirtualCaster",
    platforms: [
        .iOS("16.0")
    ],
    products: [
        .iOSApplication(
            name: "VirtualCaster",
            targets: ["AppModule"],
            bundleIdentifier: "com.example.virtualcaster",
            teamIdentifier: "",
            displayVersion: "0.1",
            bundleVersion: "1",
            appIcon: .placeholder(icon: .mic),
            accentColor: .presetColor(.orange),
            supportedDeviceFamilies: [
                .pad
            ],
            supportedInterfaceOrientations: [
                .landscapeRight,
                .landscapeLeft
            ],
            capabilities: [
                .microphone(purposeString: "VirtualCaster necesita el micrófono para mezclar tu voz.")
            ]
        )
    ],
    targets: [
        .executableTarget(
            name: "AppModule",
            path: "."
        )
    ]
)
