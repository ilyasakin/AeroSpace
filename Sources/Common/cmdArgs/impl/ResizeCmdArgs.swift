public struct ResizeCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    fileprivate init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .resize,
        help: resize_help_generated,
        flags: [
            "--window-id": windowIdSubArgParser(),
        ],
        posArgs: [
            newMandatoryPosArgParser(\.dimension, parseDimension, placeholder: "(smart|smart-opposite|width|height)"),
            newMandatoryPosArgParser(\.units, parseUnits, placeholder: "[+|-]<number>[%]"),
        ],
    )

    public var dimension: Lateinit<ResizeCmdArgs.Dimension> = .uninitialized
    public var units: Lateinit<ResizeCmdArgs.Units> = .uninitialized

    public init(
        rawArgs: [String],
        dimension: Dimension,
        units: Units,
    ) {
        self.commonState = .init(rawArgs.slice)
        self.dimension = .initialized(dimension)
        self.units = .initialized(units)
    }

    public enum Dimension: String, CaseIterable, Equatable, Sendable {
        case width, height, smart
        case smartOpposite = "smart-opposite"
    }

    public enum Units: Equatable, Sendable {
        case set(UInt)
        case add(UInt)
        case subtract(UInt)
        /// Percentage of the monitor's visible frame. Only supported for floating windows
        case setPercent(UInt)
        case addPercent(UInt)
        case subtractPercent(UInt)

        public var isPercent: Bool {
            switch self {
                case .set, .add, .subtract: false
                case .setPercent, .addPercent, .subtractPercent: true
            }
        }
    }
}

func parseResizeCmdArgs(_ args: StrArrSlice) -> ParsedCmd<ResizeCmdArgs> {
    parseSpecificCmdArgs(ResizeCmdArgs(rawArgs: args), args)
}

private func parseDimension(i: PosArgParserInput) -> ParsedCliArgs<ResizeCmdArgs.Dimension> {
    .init(parseEnum(i.arg, ResizeCmdArgs.Dimension.self), advanceBy: 1)
}

private func parseUnits(i: PosArgParserInput) -> ParsedCliArgs<ResizeCmdArgs.Units> {
    let isPercent = i.arg.hasSuffix("%")
    let raw = isPercent ? String(i.arg.dropLast()) : i.arg
    guard let number = UInt(raw.removePrefix("+").removePrefix("-")) else {
        return .fail("<number> argument must be a number", advanceBy: 1)
    }
    let units: ResizeCmdArgs.Units = switch true {
        case raw.starts(with: "+"): isPercent ? .addPercent(number) : .add(number)
        case raw.starts(with: "-"): isPercent ? .subtractPercent(number) : .subtract(number)
        default: isPercent ? .setPercent(number) : .set(number)
    }
    return .succ(units, advanceBy: 1)
}
