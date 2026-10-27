import AppKit
import Observation

/// Linux stand-in for the SwiftUI surface Window Minder uses.
/// Argument labels match the macOS SDK. This is not a runtime.

@MainActor
public protocol View {
    associatedtype Body: View
    @ViewBuilder @MainActor var body: Body { get }
}

@MainActor
@resultBuilder
public struct ViewBuilder {
    public static func buildBlock() -> EmptyView { EmptyView() }
    public static func buildBlock<V0: View>(_ v0: V0) -> V0 { v0 }
    public static func buildBlock<V0: View, V1: View>(_ v0: V0, _ v1: V1) -> TupleView<(V0, V1)> {
        TupleView((v0, v1))
    }
    public static func buildBlock<V0: View, V1: View, V2: View>(
        _ v0: V0, _ v1: V1, _ v2: V2
    ) -> TupleView<(V0, V1, V2)> {
        TupleView((v0, v1, v2))
    }
    public static func buildBlock<V0: View, V1: View, V2: View, V3: View>(
        _ v0: V0, _ v1: V1, _ v2: V2, _ v3: V3
    ) -> TupleView<(V0, V1, V2, V3)> {
        TupleView((v0, v1, v2, v3))
    }
    public static func buildBlock<V0: View, V1: View, V2: View, V3: View, V4: View>(
        _ v0: V0, _ v1: V1, _ v2: V2, _ v3: V3, _ v4: V4
    ) -> TupleView<(V0, V1, V2, V3, V4)> {
        TupleView((v0, v1, v2, v3, v4))
    }
    public static func buildOptional<V: View>(_ component: V?) -> V? { component }
    public static func buildEither<TrueContent: View, FalseContent: View>(
        first: TrueContent
    ) -> _ConditionalContent<TrueContent, FalseContent> {
        _ConditionalContent(storage: .trueContent(first))
    }
    public static func buildEither<TrueContent: View, FalseContent: View>(
        second: FalseContent
    ) -> _ConditionalContent<TrueContent, FalseContent> {
        _ConditionalContent(storage: .falseContent(second))
    }
    public static func buildExpression<V: View>(_ expression: V) -> V { expression }
}

extension Never: View {
    public typealias Body = Never
    public var body: Never { fatalError("Never") }
}

extension Optional: View where Wrapped: View {
    public typealias Body = Never
    public var body: Never { fatalError("Optional") }
}

public struct EmptyView: View {
    public typealias Body = Never
    public var body: Never { fatalError("EmptyView") }
    public init() {}
}

public struct TupleView<T>: View {
    public typealias Body = Never
    public var body: Never { fatalError("TupleView") }
    public init(_ value: T) {}
}

public struct _ConditionalContent<TrueContent: View, FalseContent: View>: View {
    enum Storage {
        case trueContent(TrueContent)
        case falseContent(FalseContent)
    }
    var storage: Storage
    public typealias Body = Never
    public var body: Never { fatalError("_ConditionalContent") }
}

public struct AnyView: View {
    public typealias Body = Never
    public var body: Never { fatalError("AnyView") }
    public init() {}
}

@MainActor
public protocol Scene {}

@MainActor
@resultBuilder
public struct SceneBuilder {
    public static func buildBlock() -> EmptyScene { EmptyScene() }
    public static func buildBlock<S0: Scene>(_ s0: S0) -> S0 { s0 }
    public static func buildBlock<S0: Scene, S1: Scene>(_ s0: S0, _ s1: S1) -> ScenePair<S0, S1> {
        ScenePair(s0, s1)
    }
    public static func buildExpression<S: Scene>(_ expression: S) -> S { expression }
}

public struct EmptyScene: Scene {
    public init() {}
}

public struct ScenePair<First: Scene, Second: Scene>: Scene {
    public init(_ first: First, _ second: Second) {}
}

public struct ModifiedScene: Scene {
    public init() {}
}

@MainActor
public protocol App {
    associatedtype Body: Scene
    @SceneBuilder @MainActor var body: Body { get }
}

public protocol WindowStyle {}

public struct HiddenTitleBarWindowStyle: WindowStyle {
    public init() {}
}

extension WindowStyle where Self == HiddenTitleBarWindowStyle {
    public static var hiddenTitleBar: HiddenTitleBarWindowStyle { HiddenTitleBarWindowStyle() }
}

public struct WindowResizability: Equatable, Sendable {
    public static let contentSize = WindowResizability()
}

extension Scene {
    public func windowStyle<S: WindowStyle>(_ style: S) -> ModifiedScene { ModifiedScene() }
    public func windowResizability(_ resizability: WindowResizability) -> ModifiedScene { ModifiedScene() }
    public func defaultSize(width: CGFloat, height: CGFloat) -> ModifiedScene { ModifiedScene() }
    public func commandsRemoved() -> ModifiedScene { ModifiedScene() }
}

public struct LocalizedStringKey: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
    public struct StringInterpolation: StringInterpolationProtocol {
        public typealias StringLiteralType = String
        public init(literalCapacity: Int, interpolationCount: Int) {}
        public mutating func appendLiteral(_ literal: String) {}
        public mutating func appendInterpolation(_ value: String) {}
    }

    public init(stringLiteral value: String) {}
    public init(stringInterpolation: StringInterpolation) {}
    public init(_ value: String) {}
}

public struct Window<Content: View>: Scene {
    public init(_ title: LocalizedStringKey, id: String, @ViewBuilder content: () -> Content) {}
}

public struct Settings<Content: View>: Scene {
    public init(@ViewBuilder content: () -> Content) {}
}

public struct OpenSettingsAction {
    public init() {}
    public func callAsFunction() {}
}

public struct EnvironmentValues {
    public var openSettings: OpenSettingsAction {
        get { OpenSettingsAction() }
        set {}
    }
}

@propertyWrapper
public struct Environment<Value> {
    public var wrappedValue: Value { fatalError("Environment") }

    public init(_ keyPath: KeyPath<EnvironmentValues, Value>) {}
    public init(_ objectType: Value.Type) where Value: AnyObject, Value: Observable {}
}

@dynamicMemberLookup
@propertyWrapper
public struct Bindable<Value> {
    private final class Box {
        var value: Value
        init(_ value: Value) { self.value = value }
    }

    private let box: Box

    public init(wrappedValue: Value) {
        box = Box(wrappedValue)
    }

    public var wrappedValue: Value {
        get { box.value }
        set { box.value = newValue }
    }

    public var projectedValue: Bindable<Value> { self }

    public subscript<Subject>(
        dynamicMember keyPath: ReferenceWritableKeyPath<Value, Subject>
    ) -> Binding<Subject> {
        let box = self.box
        return Binding(
            get: { box.value[keyPath: keyPath] },
            set: { newValue in
                var root = box.value
                root[keyPath: keyPath] = newValue
                box.value = root
            }
        )
    }
}

@propertyWrapper
public struct Binding<Value> {
    private let get: () -> Value
    private let set: (Value) -> Void

    public init(get: @escaping () -> Value, set: @escaping (Value) -> Void) {
        self.get = get
        self.set = set
    }

    public init(projectedValue: Binding<Value>) {
        self = projectedValue
    }

    public var wrappedValue: Value {
        get { get() }
        nonmutating set { set(newValue) }
    }

    public var projectedValue: Binding<Value> { self }
}

@propertyWrapper
public struct State<Value> {
    private final class Box {
        var value: Value
        init(_ value: Value) { self.value = value }
    }

    private let box: Box
    public init(wrappedValue: Value) { box = Box(wrappedValue) }
    public var wrappedValue: Value {
        get { box.value }
        nonmutating set { box.value = newValue }
    }
    public var projectedValue: Binding<Value> {
        let box = self.box
        return Binding(get: { box.value }, set: { box.value = $0 })
    }
}

public struct Font: Equatable, Sendable {
    public struct TextStyle: Hashable, Sendable {
        public static let body = TextStyle()
        public static let callout = TextStyle()
    }

    public static let body = Font()
    public static let callout = Font()
    public func monospaced() -> Font { self }
}

@propertyWrapper
public struct ScaledMetric<Value: BinaryFloatingPoint> {
    public var wrappedValue: Value
    public init(wrappedValue: Value, relativeTo textStyle: Font.TextStyle) {
        self.wrappedValue = wrappedValue
    }
}

@propertyWrapper
public struct NSApplicationDelegateAdaptor<DelegateType: NSObject & NSApplicationDelegate> {
    public init(_ delegateType: DelegateType.Type) {}
    public var wrappedValue: DelegateType { fatalError("NSApplicationDelegateAdaptor") }
}

public struct NSViewRepresentableContext<Representable> {
    public init() {}
}

@MainActor
public protocol NSViewRepresentable: View where Body == Never {
    associatedtype NSViewType: NSView
    typealias Context = NSViewRepresentableContext<Self>
    func makeNSView(context: Context) -> NSViewType
    func updateNSView(_ nsView: NSViewType, context: Context)
}

extension NSViewRepresentable {
    public var body: Never { fatalError("NSViewRepresentable") }
}

public protocol ShapeStyle {}

public struct Color: ShapeStyle, Equatable {
    public static let accentColor = Color()
    public static let primary = Color()
    public static let secondary = Color()
    public init() {}
    public init(nsColor: NSColor) {}
    public func opacity(_ opacity: CGFloat) -> Color { self }
}

extension ShapeStyle where Self == Color {
    public static var primary: Color { Color.primary }
    public static var secondary: Color { Color.secondary }
}

public protocol Shape: View {}

public struct Rectangle: Shape {
    public typealias Body = Never
    public var body: Never { fatalError("Rectangle") }
    public init() {}
}

public struct RoundedRectangle: Shape {
    public typealias Body = Never
    public var body: Never { fatalError("RoundedRectangle") }
    public init(cornerRadius: CGFloat) {}
}

@MainActor
extension Shape {
    public func fill<S: ShapeStyle>(_ content: S) -> AnyView { AnyView() }
    public func strokeBorder<S: ShapeStyle>(_ content: S, lineWidth: CGFloat) -> AnyView { AnyView() }
}

public struct VerticalAlignment: Equatable, Sendable {
    public static let center = VerticalAlignment()
    public static let firstTextBaseline = VerticalAlignment()
}

public struct HorizontalAlignment: Equatable, Sendable {
    public static let center = HorizontalAlignment()
    public static let leading = HorizontalAlignment()
}

public struct Alignment: Equatable, Sendable {
    public static let center = Alignment()
}

public struct Edge: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public struct Set: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let horizontal = Set(rawValue: 1 << 1 | 1 << 3)
        public static let vertical = Set(rawValue: 1 << 0 | 1 << 2)
    }
}

public struct Text: View {
    public typealias Body = Never
    public var body: Never { fatalError("Text") }
    public init(_ content: String) {}
}

public struct Button<Label: View>: View {
    public typealias Body = Never
    public var body: Never { fatalError("Button") }
    public init(_ title: String, action: @escaping () -> Void) where Label == Text {}
    public init(action: @escaping () -> Void, @ViewBuilder label: () -> Label) {}
}

public struct Toggle<Label: View>: View {
    public typealias Body = Never
    public var body: Never { fatalError("Toggle") }
    public init(_ title: String, isOn: Binding<Bool>) where Label == Text {}
}

public struct Spacer: View {
    public typealias Body = Never
    public var body: Never { fatalError("Spacer") }
    public init(minLength: CGFloat? = nil) {}
}

public struct HStack<Content: View>: View {
    public typealias Body = Never
    public var body: Never { fatalError("HStack") }
    public init(
        alignment: VerticalAlignment = .center,
        spacing: CGFloat? = nil,
        @ViewBuilder content: () -> Content
    ) {}
}

public struct VStack<Content: View>: View {
    public typealias Body = Never
    public var body: Never { fatalError("VStack") }
    public init(
        alignment: HorizontalAlignment = .center,
        spacing: CGFloat? = nil,
        @ViewBuilder content: () -> Content
    ) {}
}

public struct ForEach<Data: RandomAccessCollection, ID: Hashable, Content: View>: View {
    public typealias Body = Never
    public var body: Never { fatalError("ForEach") }
    public init(_ data: Data, id: KeyPath<Data.Element, ID>, @ViewBuilder content: (Data.Element) -> Content) {}
}

public struct Section<Content: View, Header: View, Footer: View>: View {
    public typealias Body = Never
    public var body: Never { fatalError("Section") }
    public init(
        @ViewBuilder content: () -> Content,
        @ViewBuilder header: () -> Header,
        @ViewBuilder footer: () -> Footer
    ) {}
    public init(
        @ViewBuilder content: () -> Content,
        @ViewBuilder header: () -> Header
    ) where Footer == EmptyView {}
    public init(@ViewBuilder content: () -> Content) where Header == EmptyView, Footer == EmptyView {}
}

public struct Form<Content: View>: View {
    public typealias Body = Never
    public var body: Never { fatalError("Form") }
    public init(@ViewBuilder content: () -> Content) {}
}

public struct FormStyle: Equatable, Sendable {
    public static let grouped = FormStyle()
}

public protocol ButtonStyle {}

public struct PlainButtonStyle: ButtonStyle {
    public init() {}
}

extension ButtonStyle where Self == PlainButtonStyle {
    public static var plain: PlainButtonStyle { PlainButtonStyle() }
}

extension View {
    public func font(_ font: Font?) -> AnyView { AnyView() }
    public func foregroundStyle<S: ShapeStyle>(_ style: S) -> AnyView { AnyView() }
    public func frame(width: CGFloat? = nil, height: CGFloat? = nil, alignment: Alignment = .center) -> AnyView {
        AnyView()
    }
    public func frame(
        minWidth: CGFloat? = nil,
        idealWidth: CGFloat? = nil,
        maxWidth: CGFloat? = nil,
        minHeight: CGFloat? = nil,
        idealHeight: CGFloat? = nil,
        maxHeight: CGFloat? = nil,
        alignment: Alignment = .center
    ) -> AnyView {
        AnyView()
    }
    public func padding(_ length: CGFloat) -> AnyView { AnyView() }
    public func padding(_ edges: Edge.Set, _ length: CGFloat) -> AnyView { AnyView() }
    public func fixedSize(horizontal: Bool, vertical: Bool) -> AnyView { AnyView() }
    public func accessibilityLabel(_ label: String) -> AnyView { AnyView() }
    public func accessibilityHint(_ hint: String) -> AnyView { AnyView() }
    public func accessibilityValue(_ value: String) -> AnyView { AnyView() }
    public func accessibilityHidden(_ hidden: Bool) -> AnyView { AnyView() }
    public func formStyle(_ style: FormStyle) -> AnyView { AnyView() }
    public func buttonStyle<S: ButtonStyle>(_ style: S) -> AnyView { AnyView() }
    public func contentShape<S: Shape>(_ shape: S) -> AnyView { AnyView() }
    public func background<V: View>(_ background: V, alignment: Alignment = .center) -> AnyView { AnyView() }
    public func background<V: View>(
        alignment: Alignment = .center,
        @ViewBuilder content: () -> V
    ) -> AnyView { AnyView() }
    public func overlay<V: View>(
        alignment: Alignment = .center,
        @ViewBuilder content: () -> V
    ) -> AnyView { AnyView() }
    public func environment<T: Observable & AnyObject>(_ object: T) -> AnyView { AnyView() }
}
