#!/usr/bin/env swift

import Foundation

struct Product : Codable {
  let name : String
}

struct Package : Codable {
  let name : String
  let products : [Product]
}

enum GitHost : String {
  case GitHub = "github.com"
}

// Find the "packages.json" file based on arguments, current directory, or the directory of the script
let argumentURL = CommandLine.arguments.dropFirst().first.flatMap(URL.init(fileURLWithPath:))
let currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true).appendingPathComponent("packages.json")
let scriptDirectoryURL = URL(fileURLWithPath: #file).deletingLastPathComponent().appendingPathComponent("packages.json")

let possibleURLs : [URL?] = [argumentURL, currentDirectoryURL, scriptDirectoryURL]

guard let url = possibleURLs.compactMap({ $0 }).first( where: { FileManager.default.fileExists(atPath: $0.path )}) else {
  print("Error: Unable to find packages.json to validate.")
  exit(1)
}

let decoder = JSONDecoder()
let data = try! Data(contentsOf: url)
let packageUrls  = try! decoder.decode([URL].self, from: data)

// Make sure all urls contain the .git extension
print("Checking all urls are valid.")
let invalidUrls = packageUrls.filter{ $0.pathExtension != "git" }

guard invalidUrls.count == 0 else {
  print("Invalid URLs missing .git extension: \(invalidUrls)")
  exit(1)
}

// Make sure there are no dupes (no dupe variants w/ .git and w/o, no case differences)
print("Checking for duplicate packages.")
let urlCounts = Dictionary(grouping: packageUrls.enumerated()) {
  URL(string: $0.element.absoluteString.lowercased())!
}.mapValues{ $0.map{ $0.offset }}.filter{$0.value.count > 1}

guard urlCounts.count == 0 else {
  print("Error: Duplicate URLs:\n\(urlCounts)")
  exit(1)
}

// Sort the array of urls
print("Checking packages are sorted.")
let sortedUrls = packageUrls.sorted{
  $0.absoluteString.lowercased() < $1.absoluteString.lowercased()
}

// Verify that there are no differences between the current JSON and the sorted JSON
let unsortedUrls = zip(packageUrls, sortedUrls).enumerated().filter{ $0.element.0 != $0.element.1 }.map{
  ($0.offset, $0.element.0)
}

guard unsortedUrls.count == 0 else {
  print("Error: packages.json is not sorted: \(unsortedUrls)")
  // If the sorting fails, save the sorted packages.json file
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted]
 
  
  let data = try! encoder.encode(sortedUrls)
  let str = String(data: data, encoding: .utf8)!.replacingOccurrences(of: "\\/", with: "/") 
  let unescapedData = str.data(using: .utf8)!
  let outputURL = url.deletingPathExtension().appendingPathExtension("sorted.json")
  try! unescapedData.write(to: outputURL)
  print("Sorted packages.json has been saved to:\n \(outputURL.path)")
  exit(1)
}

let urlComponents = URLComponents(string: "https://raw.githubusercontent.com")!

for gitURL in packageUrls {
  guard let hostString = gitURL.host else {
    print("Invalid URL: \(gitURL)")
    exit(1)
  }
  
  guard let host = GitHost(rawValue: hostString) else {
    print("Unsupported Git Host: \(hostString)")
    exit(1)
  }
  
  let outputDirURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  
  try! FileManager.default.createDirectory(at: outputDirURL, withIntermediateDirectories: false, attributes: nil)
  
  switch host {
  case .GitHub:
    var rawURLComponents = urlComponents
    let repositoryName = gitURL.deletingPathExtension().lastPathComponent
    let userName = gitURL.deletingLastPathComponent().lastPathComponent
    // https://raw.githubusercontent.com/[USER-NAME]/[REPOSITORY-NAME]/[BRANCH-NAME]/[FILE-PATH]
    rawURLComponents.path = ["", userName, repositoryName, "master", "Package.swift"].joined(separator: "/")
    let packageSwiftURL = rawURLComponents.url!
    
    let packageSwiftData : Data
    do {
     packageSwiftData = try Data(contentsOf: packageSwiftURL)
    } catch let error {
      print("Invalid Swift Package at: \(gitURL)")
      print("Decoding Error: \(error)")
      continue
    }
    try! packageSwiftData.write(to: outputDirURL.appendingPathComponent("Package.swift"))
    let pipe = Pipe()
    
    let process = Process()
    process.launchPath = "/usr/bin/swift"
    process.arguments = ["package", "dump-package"]
    process.currentDirectoryURL = outputDirURL
    process.standardOutput = pipe
    process.launch()
    process.waitUntilExit()
    
    let package : Package
    
    do {
      package = try decoder.decode(Package.self, from: pipe.fileHandleForReading.availableData)
    } catch let error {
      print("Invalid Swift Package at: \(gitURL)")
      print("Decoding Error: \(error)")
      continue
    }
    
    guard let product = package.products.first else {
      print("No product listed for: \(gitURL)")
      continue
    }
  }
}

print("Validation Succeeded.")
