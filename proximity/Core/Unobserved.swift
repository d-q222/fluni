import Combine

/// Like @Published for Combine subscribers (`$value.sink`, current value on subscribe, every set delivered), but it
/// does not fire the owning ObservableObject's objectWillChange. For values that change often and that no view
/// shows: ProximityModel.lastFix arrives about once a second from GPS and only WalkInMonitor listens, yet as
/// @Published every fix redrew every view watching the model.
@propertyWrapper
struct Unobserved<Value> {
    private let subject: CurrentValueSubject<Value, Never>

    init(wrappedValue: Value) { subject = CurrentValueSubject(wrappedValue) }

    var wrappedValue: Value {
        get { subject.value }
        nonmutating set { subject.send(newValue) }
    }

    var projectedValue: AnyPublisher<Value, Never> { subject.eraseToAnyPublisher() }
}
