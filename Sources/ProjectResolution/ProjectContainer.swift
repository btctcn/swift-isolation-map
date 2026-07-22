import Foundation

public enum ProjectContainer: Equatable, Sendable {
    case xcodeproj(URL)
    case xcworkspace(URL)
    case swiftPackage(URL)
}
