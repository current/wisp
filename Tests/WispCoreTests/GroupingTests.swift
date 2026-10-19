import Foundation
import Testing
@testable import WispCore

@Suite struct GroupingTests {
    @Test func appBundles() {
        #expect(AppGrouping.appBundle(in: "/Applications/Safari.app/Contents/MacOS/Safari") == "/Applications/Safari.app")
        #expect(AppGrouping.appBundle(in: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)")
            == "/Applications/Google Chrome.app")
        #expect(AppGrouping.appBundle(in: "/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app/Contents/MacOS/Simulator")
            == "/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app")
        #expect(AppGrouping.appBundle(in: "/usr/bin/python3") == nil)
        #expect(AppGrouping.appBundle(in: "/Applications/Foo.app") == "/Applications/Foo.app")
    }

    @Test func identities() {
        let safari = AppGrouping.identity(path: "/Applications/Safari.app/Contents/MacOS/Safari", name: "Safari")
        #expect(safari.kind == .app && safari.id == "/Applications/Safari.app" && safari.name == "Safari")

        #expect(AppGrouping.identity(path: "/usr/libexec/trustd", name: "trustd").id == AppGrouping.systemID)
        #expect(AppGrouping.identity(path: nil, name: "kernel_task").id == AppGrouping.systemID)
        #expect(AppGrouping.identity(path: "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent", name: "WebContent").id == AppGrouping.systemID)
        #expect(AppGrouping.identity(path: "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer", name: "WindowServer").id == "windowserver")
        #expect(AppGrouping.identity(path: "/System/Applications/Mail.app/Contents/MacOS/Mail", name: "Mail").kind == .app)
        #expect(AppGrouping.identity(path: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder", name: "Finder").kind == .app)
        // Apps buried in system frameworks are OS plumbing, not something the user launched.
        #expect(AppGrouping.identity(path: "/System/Library/PrivateFrameworks/Foo.framework/Support/Bar.app/Contents/MacOS/Bar", name: "Bar").id == AppGrouping.systemID)

        let node = AppGrouping.identity(path: "/opt/homebrew/bin/node", name: "node")
        #expect(node.kind == .tool && node.name == "node")
    }

    static func row(_ pid: Int32, _ group: String, cpu: Double, memory: UInt64, readable: Bool = true) -> ProcessRow {
        ProcessRow(pid: pid, ppid: 1, uid: 501, name: "p\(pid)", path: nil, responsiblePID: pid, groupID: group,
                   readable: readable, cpu: cpu, memory: memory, watts: 0.5, diskReadPerSecond: 10, diskWritePerSecond: 20,
                   networkInPerSecond: 1, networkOutPerSecond: 2, cpuTime: 0, startDate: nil)
    }

    @Test func groupsSumAndSortByCPU() {
        let rows = [
            Self.row(1, "a", cpu: 0.5, memory: 100),
            Self.row(2, "a", cpu: 0.25, memory: 50),
            Self.row(3, "b", cpu: 1.5, memory: 10),
            Self.row(4, "c", cpu: 0, memory: 1, readable: false),
        ]
        let groups = AppGrouping.group(rows) { id in (id.uppercased(), .app, nil, nil) }
        #expect(groups.map(\.id) == ["b", "a", "c"])
        let a = groups[1]
        #expect(a.name == "A")
        #expect(a.pids == [1, 2])
        #expect(a.cpu == 0.75)
        #expect(a.memory == 150)
        #expect(a.watts == 1)
        #expect(a.diskPerSecond == 60)
        #expect(a.networkPerSecond == 6)
        #expect(groups[2].unreadable == 1)
    }

    @Test func liveScanGroupsThisMachine() throws {
        let scanner = ProcessScanner()
        _ = scanner.scan(network: false)
        Thread.sleep(forTimeInterval: 0.5)
        let table = scanner.scan(network: false)
        #expect(table.processes.count > 50)
        #expect(table.apps.count < table.processes.count)
        #expect(table.apps.contains { $0.id == AppGrouping.systemID })
        let me = try #require(table.processes.first { $0.pid == getpid() })
        #expect(me.readable && me.memory > 0)
        #expect(table.machineCPU >= 0)
        let total = table.apps.reduce(0) { $0 + $1.processCount }
        #expect(total == table.processes.count)
    }
}
