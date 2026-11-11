import Foundation

/// 轻量组合根容器：按类型登记 / 解析单例服务。
///
/// 对应 Windows C# 的 `Composition.AppContainer`（手写 DI）。键为类型的
/// `ObjectIdentifier`，值为延迟构造的工厂闭包；首次解析后缓存为单例，因此
/// 工厂只运行一次。既支持具体类型，也支持协议存在类型（`(any P).self`），
/// 后者用于「接缝 protocol → 平台实现」的登记（原生实现随后续任务加入）。
///
/// 线程安全：所有登记 / 解析走一把 `NSLock`；工厂在锁外调用以免构造期回调死锁。
public final class AppContainer {

    /// 进程级共享容器（组合根装配点）。
    public static let shared = AppContainer()

    private var factories: [ObjectIdentifier: () -> Any] = [:]
    private var instances: [ObjectIdentifier: Any] = [:]
    private let lock = NSLock()

    private init() {}

    /// 登记一个延迟构造的单例工厂。重复登记同类型会覆盖并丢弃旧缓存。
    public func register<T>(_ type: T.Type, factory: @escaping () -> T) {
        let key = ObjectIdentifier(type as Any.Type)
        lock.lock()
        factories[key] = { factory() as Any }
        instances.removeValue(forKey: key)
        lock.unlock()
    }

    /// 登记一个已构造好的实例（组合根在启动期已握有对象时用）。
    public func registerInstance<T>(_ type: T.Type, _ instance: T) {
        let key = ObjectIdentifier(type as Any.Type)
        lock.lock()
        instances[key] = instance
        factories[key] = { instance as Any }
        lock.unlock()
    }

    /// 解析服务；首次调用工厂并缓存。未登记或类型不符返回 `nil`（fail-soft，
    /// 与 Windows `TryResolve` 语义一致——调用方自行判空 / 兜底）。
    public func resolve<T>(_ type: T.Type) -> T? {
        let key = ObjectIdentifier(type as Any.Type)
        lock.lock()
        if let cached = instances[key] as? T {
            lock.unlock()
            return cached
        }
        let factory = factories[key]
        lock.unlock()

        guard let factory, let instance = factory() as? T else { return nil }

        lock.lock()
        instances[key] = instance
        lock.unlock()
        return instance
    }

    /// 清空所有登记与缓存（主要给测试重置用）。
    public func reset() {
        lock.lock()
        factories.removeAll()
        instances.removeAll()
        lock.unlock()
    }
}
