import PackagePlugin
import Foundation

@main struct CuckooPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [PackagePlugin.Command] {
        let baseDir = context.package.directory
        let configPath = baseDir.appending("cuckoo.json")
        let config = try await ConfigFile.decode(from: configPath)
        
        let dependencies: [SourceModuleTarget] = target
            .dependencies
            .flatMap { dependency in
                switch dependency {
                case .product(let product):
                    return product.targets
                case .target(let target):
                    return [target]
                @unknown default:
                    return []
                }
            }
            .compactMap { $0 as? SourceModuleTarget }
            .filter { $0.kind == .generic && $0.moduleName != "Cuckoo" }
        
        let testableModules = dependencies
            .map(\.moduleName)
        
        let inputFiles = collectInputFiles(
            config: config,
            dependencies: dependencies,
            baseDir: baseDir
        )
        validateFileExistence(paths: inputFiles)
        
        let output = context
            .pluginWorkDirectory
            .appending("GeneratedMocks.swift")
        
        let buildArguments = collectBuildArguments(
            output: output,
            inputFiles: Array(inputFiles),
            testableModules: testableModules,
            options: config.options ?? []
        )
        
        return [.buildCommand(
            displayName: "Run CuckooGenerator",
            executable: try context.tool(named: "CuckooGenerator").path,
            arguments: buildArguments,
            inputFiles: [configPath] + inputFiles,
            outputFiles: [output]
        )]
    }
    
    func collectBuildArguments(
        output: PackagePlugin.Path,
        inputFiles: [PackagePlugin.Path],
        testableModules: [String],
        options: [String]
    ) -> [CustomStringConvertible] {
        var buildArguments: [CustomStringConvertible] = [
            "generate",
            "--output", output
        ]
        if !testableModules.isEmpty {
            buildArguments += ["--testable"]
            buildArguments += testableModules
        }
        if !options.isEmpty { buildArguments += options }
        buildArguments += inputFiles
        return buildArguments
    }
    
    func collectInputFiles(
        config: ConfigFile,
        dependencies: [SourceModuleTarget],
        baseDir: Path
    ) -> Set<PackagePlugin.Path> {
        var sources: [PackagePlugin.Path] = []
        if let inputFiles = config.inputFiles, 
            inputFiles.count > 0 {
            sources = inputFiles.map {
                baseDir.appending($0)
            }
        } else {
            sources = dependencies
                .flatMap(\.sourceFiles)
                .filter { $0.type == .source }
                .map(\.path)
        }
        return Set(sources)
    }
    
    /// Raises an fatalError if paths pointing to
    /// one or more non-existant files have been provided.
    func validateFileExistence(paths: Set<Path>) {
        guard !paths.isEmpty else {
            return
        }
        
        let fileManager = FileManager()
        let missingFiles = paths.filter { path in
            !fileManager.fileExists(atPath: path.string)
        }
        
        // Exit early if only valid paths have been detected
        guard !missingFiles.isEmpty else {
            return
        }
        
        let errorMessage =
            """
            Invalid configuration detected!
            Non-existing or inaccessible files:
            \(missingFiles.map({ $0.string }).joined(separator: "\n"))
            """

        fatalError(errorMessage)
    }
}

struct ConfigFile: Codable {
    enum Version: Int, Codable {
        case v1 = 1
    }

    var version: Version = .v1
    var options: [String]?
    
    /// Relative to package directory
    var inputFiles: [String]?

    static func decode(from path: Path) async throws -> Self {
        guard let data = try? await path.contents() else { return .init() }
        return try JSONDecoder().decode(self, from: data)
    }
}

extension Path {
    func contents() async throws -> Data {
        let url: URL
        if #available(macOS 13, *) {
            url = URL(filePath: string)
        } else {
            url = URL(fileURLWithPath: string)
        }
        if #available(macOS 12, *) {
            return try await url.resourceBytes.reduce(into: Data()) { $0.append($1) }
        } else {
            return try Data(contentsOf: url)
        }
    }
}
