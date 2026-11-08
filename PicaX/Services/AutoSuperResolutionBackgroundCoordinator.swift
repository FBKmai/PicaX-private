#if os(iOS)
import BackgroundTasks
import Foundation

/// Bridges the download service's automatic super-resolution queue to
/// `BGProcessingTask`. The foreground app keeps the work alive with a regular
/// background task assertion first; this coordinator requests addition system
/// time for long whole-book jobs when the app has been backgrounded.
@MainActor
final class AutoSuperResolutionBackgroundCoordinator {
    static let shared = AutoSuperResolutionBackgroundCoordinator()
    static let taskIdentifier = "moye.PicaX.superresolution"

    private var activeTask: BGProcessingTask?
    private var observerTask: Task<Void, Never>?
    private var isRegistered = false

    private init() {}

    /// Must be called before the app finishes launching.
    func register() {
        guard !isRegistered else { return }
        isRegistered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.taskIdentifier,
            using: nil
        ) { task in
            let box = AutoSuperResolutionSendableBox(value: task)
            Task { @MainActor in
                guard let processingTask = box.value as? BGProcessingTask else {
                    box.value.setTaskCompleted(success: false)
                    return
                }
                Self.shared.handle(processingTask)
            }
        }
    }

    func scheduleIfNeeded() {
        guard DownloadSettingsKey.allowsAutoSuperResolutionInBackground() else { return }
        guard activeTask == nil else { return }
        guard DownloadService.hasPersistedAutoSuperResolutionWork() else { return }

        let request = BGProcessingTaskRequest(identifier: Self.taskIdentifier)
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 5)
        do {
            // Replace a stale request instead of stacking duplicates.
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Scheduling is best effort. Foreground processing and the regular
            // background assertion still handle the queue.
        }
    }

    func applicationDidBecomeActive() {
        guard activeTask != nil else { return }
        // The app is now in the foreground; stop holding the processing task
        // while the render model keeps running under normal foreground rules.
        finishActiveTask(success: true)
    }

    func cancelIfIdle() {
        guard activeTask == nil else { return }
        guard !DownloadService.hasPersistedAutoSuperResolutionWork() else { return }
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
    }

    private func handle(_ task: BGProcessingTask) {
        guard activeTask == nil else {
            task.setTaskCompleted(success: false)
            return
        }

        guard DownloadSettingsKey.allowsAutoSuperResolutionInBackground() else {
            task.setTaskCompleted(success: true)
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
            return
        }
        let processor = DownloadService.shared
        guard processor.hasPendingAutoSuperResolutionWork else {
            task.setTaskCompleted(success: true)
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
            return
        }

        activeTask = task
        task.expirationHandler = { [weak self] in
            Task { @MainActor in
                self?.handleExpiration()
            }
        }

        processor.processAutoSuperResolutionQueueIfNeeded()
        observerTask?.cancel()
        observerTask = Task { [weak self, weak processor] in
            while !Task.isCancelled {
                guard let self else { return }
                guard let processor else {
                    self.finishActiveTask(success: false)
                    return
                }
                if !processor.hasPendingAutoSuperResolutionWork {
                    self.finishActiveTask(success: true)
                    return
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func handleExpiration() {
        let hadPendingWork = DownloadService.hasPersistedAutoSuperResolutionWork()
        finishActiveTask(success: false)
        if hadPendingWork {
            // Ask for another background slot before the process is suspended.
            scheduleIfNeeded()
        }
    }

    private func finishActiveTask(success: Bool) {
        observerTask?.cancel()
        observerTask = nil
        guard let task = activeTask else { return }
        activeTask = nil
        task.setTaskCompleted(success: success)
        cancelIfIdle()
    }
}

private nonisolated struct AutoSuperResolutionSendableBox<Value>: @unchecked Sendable {
    let value: Value
}
#endif
