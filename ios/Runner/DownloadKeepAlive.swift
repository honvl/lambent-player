import BackgroundTasks
import UIKit

/// Keeps the app running for a download that goes through the Lambent tunnel.
/// The tunnel lives in this process, so Apple's background downloader can only
/// reach the PC while the app runs. iOS 26 and later hold it in a continued
/// task, begun from the screen, which shows its progress as a live activity.
/// Older systems get a scheduled task, run when iOS chooses. When either ends,
/// the transfer parks and resumes from the same byte the next time the app runs.
final class DownloadKeepAlive {
  private let scheduledIdentifier: String
  private let continuedPrefix: String
  private let wake: (@escaping () -> Void) -> Void
  private var task: BGTask?
  private var submitted = false
  private var active = false
  private var thousandths: Int64 = 0

  /// [wake] brings Dart's download service up and calls back when it has
  /// reported what is running.
  init(bundleIdentifier: String, wake: @escaping (@escaping () -> Void) -> Void) {
    scheduledIdentifier = bundleIdentifier + ".downloads.scheduled"
    continuedPrefix = bundleIdentifier + ".downloads.continued."
    self.wake = wake
  }

  private var usesContinuedTask: Bool {
    if #available(iOS 26.0, *) { return true }
    return false
  }

  /// Must run before the app finishes launching. A continued task registers
  /// when it is submitted instead, which BGTaskScheduler allows.
  func register() {
    guard !usesContinuedTask else { return }
    BGTaskScheduler.shared.register(forTaskWithIdentifier: scheduledIdentifier, using: .main) {
      [weak self] task in
      self?.runScheduled(task)
    }
  }

  /// What Dart reports: whether a tunnel download is in flight, and how far.
  func update(active: Bool, fraction: Double) {
    self.active = active
    thousandths = Int64((min(max(fraction, 0), 1) * 1000).rounded())
    reportProgress()
    if active {
      submitContinuedTask()
    } else {
      finish(success: true)
    }
  }

  func appBecameActive() {
    submitContinuedTask()
    // The app is on screen, so a scheduled task has nothing left to hold.
    if !usesContinuedTask {
      BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: scheduledIdentifier)
      finish(success: true)
    }
  }

  func appEnteredBackground() {
    scheduleIfNeeded()
  }

  private func scheduleIfNeeded() {
    guard active, !usesContinuedTask else { return }
    let request = BGProcessingTaskRequest(identifier: scheduledIdentifier)
    request.requiresNetworkConnectivity = true
    do {
      try BGTaskScheduler.shared.submit(request)
    } catch {
      NSLog("[DownloadKeepAlive] could not schedule: %@", "\(error)")
    }
  }

  private func runScheduled(_ task: BGTask) {
    begin(task)
    // A launch by the task itself has no window, and nothing has told this
    // object about the downloads yet.
    wake { [weak self] in
      guard let self, self.task === task, !self.active else { return }
      self.finish(success: true)
    }
  }

  private func submitContinuedTask() {
    guard #available(iOS 26.0, *), active, !submitted, task == nil,
      UIApplication.shared.applicationState == .active
    else { return }
    let identifier = continuedPrefix + UUID().uuidString
    let registered = BGTaskScheduler.shared.register(
      forTaskWithIdentifier: identifier, using: .main
    ) { [weak self] task in
      self?.submitted = false
      self?.begin(task)
    }
    guard registered else { return }
    let request = BGContinuedProcessingTaskRequest(
      identifier: identifier,
      title: "Downloading",
      subtitle: "Your download continues in the background"
    )
    do {
      try BGTaskScheduler.shared.submit(request)
      submitted = true
    } catch {
      NSLog("[DownloadKeepAlive] could not start: %@", "\(error)")
    }
  }

  private func begin(_ task: BGTask) {
    self.task = task
    task.expirationHandler = { [weak self, weak task] in
      DispatchQueue.main.async {
        guard let self, self.task === task else { return }
        self.finish(success: false)
        self.scheduleIfNeeded()
      }
    }
    if !active, usesContinuedTask {
      finish(success: true)
      return
    }
    reportProgress()
  }

  private func reportProgress() {
    guard #available(iOS 26.0, *), let task = task as? BGContinuedProcessingTask else { return }
    // iOS may end a task whose progress looks stalled.
    task.progress.totalUnitCount = 1000
    task.progress.completedUnitCount = thousandths
  }

  private func finish(success: Bool) {
    guard let task else { return }
    self.task = nil
    task.setTaskCompleted(success: success)
  }
}
