// 자료의 원본과 쪽 이미지를 자료 버킷과 맞춘다 (DATA.md 의 자료 버킷, DECISIONS.md 31).
// 로컬에 없는 원본은 받고(새 맥, 다시 깐 앱), 버킷에 다 올리지 않은 자료는 원본, 바꾼 파일, 쪽 이미지를 올린다.
// 다 올린 자료는 앱 지원 폴더에 적어 두어 켤 때마다 버킷에 다시 묻지 않는다.
import Foundation

public enum SourceFiles {
  public struct Outcome: Sendable, Equatable {
    public var at: String
    public var bucket: String
    public var uploaded = 0
    public var downloaded = 0
    // 올리지 못하거나 받지 못한 까닭 (처음 것)
    public var error: String?

    public init(at: String, bucket: String) {
      self.at = at
      self.bucket = bucket
    }
  }

  // 함께 올리고 받는 수
  static let parallel = 6

  // 버킷에 다 올린 자료 id 목록 (버킷마다)
  static func doneFile(_ folders: AppFolders, bucket: String) -> URL {
    folders.support.appending(path: "buckets/\(bucket)/uploaded.txt")
  }

  static func done(_ folders: AppFolders, bucket: String) -> Set<String> {
    Set((FileOps.readIfExists(doneFile(folders, bucket: bucket)) ?? "").split(separator: "\n").map(String.init))
  }

  // 자료 하나가 버킷에 둘 파일 (객체 이름, 로컬 자리, 형식)
  static func files(_ source: SourceSummary, folders: AppFolders) -> [(object: String, local: URL, type: String)] {
    let folder = source.folder
    let ext = (source.meta.original.name as NSString).pathExtension.lowercased()
    var out = [(BucketObject.file(folder.id, "original.\(ext)"), folder.url.appending(path: "original.\(ext)"), "application/octet-stream")]
    if let converted = source.meta.converted?.to {
      out.append((BucketObject.file(folder.id, converted), folder.url.appending(path: converted), converted.hasSuffix(".pdf") ? "application/pdf" : "image/jpeg"))
    }
    for n in 1...max(source.meta.pages, 1) {
      out.append((BucketObject.page(folder.id, n), SourcePages.viewImage(folder, page: n, folders: folders), "image/heic"))
    }
    return out
  }

  public static func sync(_ library: SourceLibrary, folders: AppFolders, client: GCSClient) async -> Outcome {
    var outcome = Outcome(at: Clock.isoLocal(), bucket: client.bucket)
    // 로컬에 없는 원본과 바꾼 파일을 받는다 (쪽 이미지는 볼 때 받거나 그린다)
    for source in library.sources {
      for file in files(source, folders: folders) where !file.object.hasSuffix(".heic") && !FileOps.exists(file.local) {
        do {
          try FileOps.writeAtomic(try await client.get(file.object), to: file.local)
          outcome.downloaded += 1
        } catch {
          outcome.error = outcome.error ?? error.localizedDescription
        }
      }
    }
    // 다 올리지 않은 자료를 올린다
    var finished = done(folders, bucket: client.bucket)
    for source in library.sources where !finished.contains(source.id) {
      do {
        try SourcePages.makeViewImages(source.folder, pages: source.meta.pages, folders: folders)
        outcome.uploaded += try await upload(files(source, folders: folders), client: client)
        finished.insert(source.id)
        try FileOps.makeDirectory(doneFile(folders, bucket: client.bucket).deletingLastPathComponent())
        try FileOps.writeAtomic(finished.sorted().joined(separator: "\n") + "\n", to: doneFile(folders, bucket: client.bucket))
      } catch {
        outcome.error = outcome.error ?? "\(source.id): \(error.localizedDescription)"
      }
    }
    return outcome
  }

  // 버킷에 없는 것만 올린다. 하나라도 못 올리면 던진다 (그 자료는 다음에 다시 한다).
  static func upload(_ files: [(object: String, local: URL, type: String)], client: GCSClient) async throws -> Int {
    try await withThrowingTaskGroup(of: Int.self) { group in
      var queue = files[...]
      var count = 0
      func add() {
        guard let file = queue.popFirst() else { return }
        group.addTask {
          if try await client.exists(file.object) { return 0 }
          guard let data = try? Data(contentsOf: file.local) else { throw BucketError("로컬에 없습니다: \(file.local.lastPathComponent)") }
          try await client.put(file.object, data: data, contentType: file.type)
          return 1
        }
      }
      for _ in 0..<parallel { add() }
      while let n = try await group.next() {
        count += n
        add()
      }
      return count
    }
  }

  // 맥의 쪽 보기: 로컬에 없으면 원본에서 그리고, 원본도 없으면 버킷에서 받는다
  public static func viewImage(_ source: SourceSummary, page: Int, folders: AppFolders, client: GCSClient?) async throws -> URL {
    let local = SourcePages.viewImage(source.folder, page: page, folders: folders)
    if FileOps.exists(local) { return local }
    if source.folder.renderable != nil {
      try SourcePages.makeViewImages(source.folder, pages: source.meta.pages, folders: folders, only: page)
      if FileOps.exists(local) { return local }
    }
    guard let client else { throw BucketError("이 쪽의 이미지가 없습니다. 자료 버킷을 연결하면 받습니다") }
    try FileOps.makeDirectory(local.deletingLastPathComponent())
    try FileOps.writeAtomic(try await client.get(BucketObject.page(source.id, page)), to: local)
    return local
  }
}
