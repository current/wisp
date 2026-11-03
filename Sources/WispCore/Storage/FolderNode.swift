import Foundation

/// One folder (or one large file) in a storage scan. Sizes are allocated bytes for
/// the whole subtree. Only the largest children are kept; the rest are folded into
/// `otherSize`, so a scan of a whole disk stays a few megabytes.
public final class FolderNode: Codable, @unchecked Sendable {
    public var name: String
    public var size: UInt64
    /// Files in the subtree.
    public var files: UInt64
    /// Latest modification time in the subtree, seconds since 1970.
    public var modified: Double
    /// Latest modification of this folder itself, its own files and the children not kept.
    public var ownModified: Double
    public var isFile: Bool
    /// The folder could not be read (permissions or privacy) or was left alone on purpose.
    public var locked: Bool
    public var children: [FolderNode]
    /// Bytes and items in children that were not kept.
    public var otherSize: UInt64
    public var otherCount: UInt32

    public init(name: String, size: UInt64 = 0, files: UInt64 = 0, modified: Double = 0, ownModified: Double = 0,
                isFile: Bool = false, locked: Bool = false, children: [FolderNode] = [], otherSize: UInt64 = 0, otherCount: UInt32 = 0) {
        self.name = name
        self.size = size
        self.files = files
        self.modified = modified
        self.ownModified = ownModified
        self.isFile = isFile
        self.locked = locked
        self.children = children
        self.otherSize = otherSize
        self.otherCount = otherCount
    }

    enum CodingKeys: String, CodingKey {
        case name = "n", size = "s", files = "f", modified = "m", ownModified = "o", isFile = "i", locked = "l", children = "c"
        case otherSize = "os", otherCount = "oc"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        size = try c.decode(UInt64.self, forKey: .size)
        files = try c.decodeIfPresent(UInt64.self, forKey: .files) ?? 0
        modified = try c.decodeIfPresent(Double.self, forKey: .modified) ?? 0
        ownModified = try c.decodeIfPresent(Double.self, forKey: .ownModified) ?? 0
        isFile = try c.decodeIfPresent(Bool.self, forKey: .isFile) ?? false
        locked = try c.decodeIfPresent(Bool.self, forKey: .locked) ?? false
        children = try c.decodeIfPresent([FolderNode].self, forKey: .children) ?? []
        otherSize = try c.decodeIfPresent(UInt64.self, forKey: .otherSize) ?? 0
        otherCount = try c.decodeIfPresent(UInt32.self, forKey: .otherCount) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(size, forKey: .size)
        if files > 0 { try c.encode(files, forKey: .files) }
        if modified > 0 { try c.encode(modified.rounded(), forKey: .modified) }
        if ownModified > 0 { try c.encode(ownModified.rounded(), forKey: .ownModified) }
        if isFile { try c.encode(true, forKey: .isFile) }
        if locked { try c.encode(true, forKey: .locked) }
        if !children.isEmpty { try c.encode(children, forKey: .children) }
        if otherSize > 0 { try c.encode(otherSize, forKey: .otherSize) }
        if otherCount > 0 { try c.encode(otherCount, forKey: .otherCount) }
    }

    public func child(_ name: String) -> FolderNode? { children.first { $0.name == name } }

    /// Bytes in files directly inside this folder (big files listed as children included).
    public var ownFiles: UInt64 {
        let folders = children.reduce(otherSize) { $0 + ($1.isFile ? 0 : $1.size) }
        return size > folders ? size - folders : 0
    }

    /// The node at a path below this one ("Library/Caches"), if it was kept.
    public func descendant(_ relative: String) -> FolderNode? {
        var node = self
        for part in relative.split(separator: "/") where !part.isEmpty {
            guard let next = node.child(String(part)) else { return nil }
            node = next
        }
        return node
    }

    /// The deepest kept node on the way to `relative`, with the path it stands for.
    public func deepest(_ relative: String) -> (node: FolderNode, path: [String]) {
        var node = self
        var path: [String] = []
        for part in relative.split(separator: "/") where !part.isEmpty {
            guard let next = node.child(String(part)), !next.isFile else { break }
            node = next
            path.append(String(part))
        }
        return (node, path)
    }

    /// Every kept node, depth first, with its path relative to this node. Stops
    /// descending where `visit` returns false.
    public func walk(_ prefix: String = "", _ visit: (FolderNode, String) -> Bool) {
        for child in children {
            let path = prefix.isEmpty ? child.name : prefix + "/" + child.name
            if visit(child, path) { child.walk(path, visit) }
        }
    }

    /// Number of kept nodes, for keeping an eye on memory.
    public var nodeCount: Int { 1 + children.reduce(0) { $0 + $1.nodeCount } }

    /// A new tree with `replacement` where the node at `path` was. Nodes along the path
    /// are copied and everything else is shared, so a tree already handed to the
    /// interface never changes under it. Returns self when the path is not in the tree.
    public func replacing(at path: [String], with replacement: FolderNode) -> FolderNode {
        guard let first = path.first, let index = children.firstIndex(where: { $0.name == first }) else { return self }
        let old = children[index]
        let new = path.count == 1 ? replacement : old.replacing(at: Array(path.dropFirst()), with: replacement)
        new.name = old.name
        var children = self.children
        children[index] = new
        children.sort { $0.size > $1.size }
        return FolderNode(name: name, size: size &- old.size &+ new.size, files: files &- old.files &+ new.files,
                          modified: max(modified, new.modified), ownModified: ownModified, isFile: isFile, locked: locked,
                          children: children, otherSize: otherSize, otherCount: otherCount)
    }

    /// A copy without children below `depth`, for cheap snapshots of a tree.
    public func trimmed(depth: Int) -> FolderNode {
        FolderNode(name: name, size: size, files: files, modified: modified, ownModified: ownModified, isFile: isFile, locked: locked,
                   children: depth > 0 ? children.map { $0.trimmed(depth: depth - 1) } : [],
                   otherSize: depth > 0 ? otherSize : 0, otherCount: depth > 0 ? otherCount : 0)
    }
}
