import Testing
@testable import WispCore

@Test func missingDashboardLayoutGivesDefault() {
    #expect(DashboardBlock.layout(from: nil) == DashboardBlock.defaultLayout)
}

@Test func unknownAndRepeatedBlocksAreDropped() {
    #expect(DashboardBlock.layout(from: ["apps", "weather", "cpu", "apps"]) == [.apps, .cpu])
    #expect(DashboardBlock.layout(from: []) == [])
}

@Test func movingBlocksReordersAndAdds() {
    let layout: [DashboardBlock] = [.cpu, .meters, .apps]
    #expect(DashboardBlock.moving(.apps, to: 0, in: layout) == [.apps, .cpu, .meters])
    #expect(DashboardBlock.moving(.cpu, to: 2, in: layout) == [.meters, .apps, .cpu])
    #expect(DashboardBlock.moving(.gpu, to: 1, in: layout) == [.cpu, .gpu, .meters, .apps])
    #expect(DashboardBlock.moving(.gpu, to: 99, in: layout) == [.cpu, .meters, .apps, .gpu])
}

@Test func dashboardDemandFollowsBlocks() {
    let demand = DashboardBlock.demand(of: [.cpu, .network])
    #expect(demand.contains(.cpu))
    #expect(demand.contains(.network))
    #expect(!demand.contains(.processes))
    #expect(!demand.contains(.gpu))
    #expect(DashboardBlock.demand(of: [.agents]).contains(.processes))
}
