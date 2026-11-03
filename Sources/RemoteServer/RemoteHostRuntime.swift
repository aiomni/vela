import AppKit
import RemoteCore
import Darwin

/// Owned by the Vela application delegate. No helper process or login item.
@MainActor
public final class RemoteHostRuntime {
    public let service: RemoteHostService
    private var polling: Task<Void, Never>?
    private var stopping: Task<Void, Never>?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var lockFD: Int32 = -1

    public init(files: RemoteFiles = RemoteFiles(), addressProvider: (@MainActor () -> [String])? = nil,
                authenticator: RemoteAuthenticator = RemoteAuthenticator()) {
        service = RemoteHostService(files: files, addressProvider: addressProvider, authenticator: authenticator)
    }

    public func start() throws {
        guard polling == nil, stopping == nil else { return }
        try service.files.prepare()
        let descriptor = open(service.files.directory.appendingPathComponent("host.lock").path,
                              O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw RemoteError.message("Unable to open the remote service lock.") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw RemoteError.message("Another Vela instance owns remote access. Quit that instance and reopen Vela.")
        }
        lockFD = descriptor
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification) { await $0.suspend(true) }
        observe(workspace, NSWorkspace.didWakeNotification) { await $0.suspend(false) }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { await $0.setSessionActive(false) }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { await $0.setSessionActive(true) }
        // These notifications only change availability, never grant capture/input permission.
        observe(DistributedNotificationCenter.default(), NSNotification.Name("com.apple.screenIsLocked")) {
            await $0.setSessionActive(false)
        }
        observe(DistributedNotificationCenter.default(), NSNotification.Name("com.apple.screenIsUnlocked")) {
            await $0.setSessionActive(true)
        }
        let service = self.service
        polling = Task {
            while !Task.isCancelled {
                await service.tick()
                do { try await Task.sleep(for: .seconds(1)) }
                catch { break }
            }
        }
    }

    public func stop() async {
        if let stopping { await stopping.value; return }
        guard let pending = polling else { return }
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        pending.cancel()
        let task = Task {
            // Drain an in-flight start/tick before closing the listener so it
            // cannot finish starting a new listener after application shutdown.
            await pending.value
            await service.shutdown()
            if lockFD >= 0 {
                service.publish()
                close(lockFD); lockFD = -1
            }
            polling = nil
        }
        stopping = task
        await task.value
    }

    private func observe(_ center: NotificationCenter, _ name: NSNotification.Name,
                         action: @escaping @MainActor (RemoteHostService) async -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.stopping == nil, self.polling != nil else { return }
                await action(self.service)
            }
        }
        observers.append((center, token))
    }
}
