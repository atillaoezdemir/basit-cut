import Foundation
import Testing
@testable import BasitCutCore

struct ProjectCodingTests {
    @Test func jsonRoundTrip() throws {
        var project = Fixture.project(clipSeconds: [4, 6])
        try TimelineEditor.setTransition(Transition(kind: .blackFade, duration: s(1.5)), after: project.clips[0].id, in: &project)
        project.crop = CropSetting(mode: .ratio9x16, rect: NormalizedRect(x: 0.2, y: 0, width: 0.3, height: 1))
        project.cover = CoverFrame(sourceID: project.sources[0].id, time: s(1))

        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(Project.self, from: data)
        #expect(decoded == project)
        #expect(decoded.formatVersion == Project.currentFormatVersion)
    }
}
