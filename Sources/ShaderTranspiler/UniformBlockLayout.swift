import Foundation

/// One member's placement inside the gathered uniform block.
public struct UniformBlockMember: Sendable, Hashable, Codable {
    public var name: String
    public var type: ShaderUniformType
    /// Byte offset from the start of the block.
    public var offset: Int
    /// Element count for arrays, `nil` for scalars.
    public var arrayLength: Int?
    /// Bytes between consecutive array elements. Equals the member size when not an array.
    public var stride: Int
    /// Bytes this member occupies, including internal array padding but not trailing
    /// padding before the next member.
    public var size: Int

    public init(
        name: String,
        type: ShaderUniformType,
        offset: Int,
        arrayLength: Int? = nil,
        stride: Int,
        size: Int
    ) {
        self.name = name
        self.type = type
        self.offset = offset
        self.arrayLength = arrayLength
        self.stride = stride
        self.size = size
    }
}

/// Byte layout of the constant buffer a preprocessed shader expects.
///
/// This is the contract between the emitted GLSL and the Swift code that fills the buffer.
/// It has to agree with the offsets SPIRV-Cross bakes into the generated MSL struct, which
/// it does because both follow std140 — glslang records explicit offsets in the SPIR-V and
/// SPIRV-Cross pads the MSL struct to match them. The alternative, reflecting the compiled
/// MSL back out through the C bridge, would make the binding contract depend on a
/// SPIRV-Cross version rather than on a published rule.
public struct UniformBlockLayout: Sendable, Hashable, Codable {
    public var members: [UniformBlockMember]
    /// Total size in bytes, rounded up to a 16-byte boundary as std140 requires.
    public var size: Int

    public init(members: [UniformBlockMember], size: Int) {
        self.members = members
        self.size = size
    }

    public var isEmpty: Bool { members.isEmpty }

    public func member(named name: String) -> UniformBlockMember? {
        members.first { $0.name == name }
    }

    /// Computes std140 placement for `declarations`, in declaration order.
    ///
    /// Order matters and is not sorted: the emitted GLSL declares members in this order, so
    /// reordering here would silently disagree with the block it describes.
    public static func std140(for declarations: [ShaderUniformDeclaration]) -> UniformBlockLayout {
        var members: [UniformBlockMember] = []
        var cursor = 0

        for declaration in declarations where !declaration.type.isOpaque {
            let base = declaration.type.std140Alignment
            let baseSize = declaration.type.std140Size

            let alignment: Int
            let stride: Int
            let size: Int
            if let count = declaration.arrayLength {
                // std140 rounds an array's element alignment up to a vec4, so an array of
                // floats is spaced 16 bytes apart rather than 4. This is the rule most
                // often got wrong, and getting it wrong misreads every element but the
                // first.
                alignment = max(base, 16)
                stride = roundUp(baseSize, to: alignment)
                size = stride * count
            } else {
                alignment = base
                stride = baseSize
                size = baseSize
            }

            let offset = roundUp(cursor, to: alignment)
            members.append(UniformBlockMember(
                name: declaration.name,
                type: declaration.type,
                offset: offset,
                arrayLength: declaration.arrayLength,
                stride: stride,
                size: size
            ))
            cursor = offset + size
        }

        return UniformBlockLayout(members: members, size: roundUp(cursor, to: 16))
    }

    static func roundUp(_ value: Int, to alignment: Int) -> Int {
        guard alignment > 1 else { return value }
        let remainder = value % alignment
        return remainder == 0 ? value : value + (alignment - remainder)
    }
}
