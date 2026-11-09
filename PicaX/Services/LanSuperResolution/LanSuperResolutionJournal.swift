import Foundation

@MainActor
enum LanSRJournal {
    static func load() throws -> [LanSRLocalJob] {
        let file = try LanSRFiles.root().appendingPathComponent("jobs-v1.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        guard try LanSRFiles.size(file) <= 32 * 1024 * 1024 else { throw LanSRError.message("局域网任务日志过大，已停止自动恢复。") }
        let jobs = try JSONDecoder().decode([LanSRLocalJob].self, from: Data(contentsOf: file))
        guard Set(jobs.map(\.id)).count == jobs.count,
              jobs.allSatisfy({ LanSRContract.isUUID($0.id) && LanSRContract.isUUID($0.serverID) }) else {
            throw LanSRError.message("局域网任务日志无效，未覆盖日志或下载文件。")
        }
        for job in jobs { try job.validateJournal() }
        return jobs
    }
    static func save(_ jobs: [LanSRLocalJob]) throws {
        guard Set(jobs.map(\.id)).count == jobs.count else { throw LanSRError.message("拒绝写入重复的电脑任务。") }
        for job in jobs { try job.validateJournal() }
        let file = try LanSRFiles.root().appendingPathComponent("jobs-v1.json")
        let data = try JSONEncoder().encode(jobs)
        guard data.count <= 32 * 1024 * 1024 else { throw LanSRError.message("任务日志已满，请移除已完成任务。") }
        try data.write(to: file, options: .atomic)
        let handle = try FileHandle(forWritingTo: file)
        try handle.synchronize()
        try handle.close()
    }
}
