import Foundation
import Testing
@testable import ProjectResolution

@Test func projectContainerEquality() {
    let url = URL(fileURLWithPath: "/tmp/MyProject.xcodeproj")
    #expect(ProjectContainer.xcodeproj(url) == ProjectContainer.xcodeproj(url))
}
