import ArgumentParser
import Foundation
import SwiftDoc
import SwiftMarkup
import SwiftSemantics
import struct SwiftSemantics.Protocol

#if os(Linux)
import FoundationNetworking
#endif

extension SwiftDoc {
  struct Generate: ParsableCommand {
    enum Format: String, ExpressibleByArgument {
      case commonmark
      case html
    }

    struct Options: ParsableArguments {
      @Argument(help: "One or more paths to Swift files")
      var inputs: [String]

      @Option(name: [.long, .customShort("n")],
              help: "The name of the module")
      var moduleName: String

      @Option(name: .shortAndLong,
              help: "The path for generated output")
      var output: String = ".build/documentation"

      @Option(name: .shortAndLong,
              help: "The output format")
      var format: Format = .commonmark

      @Option(name: .customLong("base-url"),
              help: "The base URL used for all relative URLs in generated documents.")
      
      var baseURL: String = "/"

      @Option(name: .customLong("excluded-symbols"),
              default: nil,
              help: "A file containing a line separated list of symbols to be excluded from the generated documentation")
      var exclusionsFilePath: String?
    }

    static var configuration = CommandConfiguration(abstract: "Generates Swift documentation")

    @OptionGroup()
    var options: Options

    func run() throws {
      let module = try Module(name: options.moduleName, paths: options.inputs, exclusionsFilePath: options.exclusionsFilePath)
      let baseURL = options.baseURL

      let outputDirectoryURL = URL(fileURLWithPath: options.output)
      try fileManager.createDirectory(at: outputDirectoryURL, withIntermediateDirectories: true)

      do {
        let format = options.format

        var pages: [String: Page] = [:]

        var globals: [String: [Symbol]] = [:]
        for symbol in module.interface.topLevelSymbols.filter({ $0.isPublic }) {
          switch symbol.api {
          case is Class, is Enumeration, is Structure, is Protocol:
            pages[route(for: symbol)] = TypePage(module: module, symbol: symbol, baseURL: baseURL)
          case let `typealias` as Typealias:
            pages[route(for: `typealias`.name)] = TypealiasPage(module: module, symbol: symbol, baseURL: baseURL)
          case let function as Function where !function.isOperator:
            globals[function.name, default: []] += [symbol]
          case let variable as Variable:
            globals[variable.name, default: []] += [symbol]
          default:
            continue
          }
        }

        for (name, symbols) in globals {
            pages[route(for: name)] = GlobalPage(module: module, name: name, symbols: symbols, baseURL: baseURL)
        }

        guard !pages.isEmpty else {
            logger.warning("No public API symbols were found at the specified path. No output was written.")
            return
        }

        if pages.count == 1, let page = pages.first?.value {
          let filename: String
          switch format {
          case .commonmark:
            filename = "Home.md"
          case .html:
            filename = "index.html"
          }

          let url = outputDirectoryURL.appendingPathComponent(filename)
          try page.write(to: url, format: format)
        } else {
          switch format {
          case .commonmark:
            pages["Home"] = HomePage(module: module, baseURL: baseURL)
            pages["_Sidebar"] = SidebarPage(module: module, baseURL: baseURL)
            pages["_Footer"] = FooterPage(baseURL: baseURL)
          case .html:
            pages["Home"] = HomePage(module: module, baseURL: baseURL)
          }

          try pages.map { $0 }.parallelForEach {
            let filename: String
            switch format {
            case .commonmark:
              filename = "\($0.key).md"
            case .html where $0.key == "Home":
              filename = "index.html"
            case .html:
              filename = "\($0.key)/index.html"
            }

            let url = outputDirectoryURL.appendingPathComponent(filename)
            try $0.value.write(to: url, format: format)
          }
        }

        if case .html = format {
          let cssData = try fetchRemoteCSS()
          let cssURL = outputDirectoryURL.appendingPathComponent("all.css")
          try writeFile(cssData, to: cssURL)
        }

      } catch {
        logger.error("\(error)")
      }
    }
  }
}

func fetchRemoteCSS() throws -> Data {
  let url = URL(string: "https://raw.githubusercontent.com/SwiftDocOrg/swift-doc/master/Resources/all.min.css")!
  return try Data(contentsOf: url)
}
