import Foundation

/// 公开更新检查：JSON API 优先，限流/网络错误时回退到官方 latest 重定向。
/// 使用无 Cookie、无认证的独立会话，不读取钥匙串或个人 GitHub 凭证。
enum UpdateChecker {
    struct Release {
        let version: String
        let pageURL: URL
        let notes: String?
    }
    struct CheckError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    typealias Transport = (URLRequest, @escaping (Data?, HTTPURLResponse?, Error?) -> Void) -> Void
    private static let repo = "Visero/mac-kit"
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()
    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }
    static var currentBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }
    private static func send(_ request: URLRequest, completion: @escaping (Data?, HTTPURLResponse?, Error?) -> Void) {
        session.dataTask(with: request) { data, response, error in
            completion(data, response as? HTTPURLResponse, error)
        }.resume()
    }
    private static func request(_ url: URL, method: String = "GET", transport: @escaping Transport,
                                completion: @escaping (Data?, HTTPURLResponse?, Error?) -> Void) {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        req.httpMethod = method
        req.setValue("MacKit/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        if url.host == "api.github.com" {
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        }
        transport(req, completion)
    }
    static func check(completion: @escaping (Result<Release?, Error>) -> Void) {
        check(transport: send, completion: completion)
    }
    static func check(transport: @escaping Transport, completion: @escaping (Result<Release?, Error>) -> Void) {
        let api = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
        request(api, transport: transport) { data, response, error in
            if error == nil, response?.statusCode == 200, let data, let release = parseRelease(data) {
                completion(.success(release))
                return
            }
            // 不重试被限流的 API；官方公开重定向是独立的版本来源。
            let original = failure(response: response, error: error)
            let noRelease = error == nil && response?.statusCode == 404
            let web = URL(string: "https://github.com/\(repo)/releases/latest")!
            request(web, method: "HEAD", transport: transport) { _, response, error in
                if error == nil, response?.statusCode == 200, let url = response?.url,
                   let release = parseReleasePage(url) {
                    completion(.success(release))
                    return
                }
                // 只有明确未发布时才查 tags；错误、坏数据不能当作“已是最新”。
                guard noRelease, error == nil, response?.statusCode == 404 else {
                    let webError = failure(response: response, error: error)
                    completion(.failure(CheckError(message: "\(original.localizedDescription)；发布页：\(webError.localizedDescription)")))
                    return
                }
                let tagsURL = URL(string: "https://api.github.com/repos/\(repo)/tags")!
                request(tagsURL, transport: transport) { data, response, error in
                    guard error == nil, response?.statusCode == 200, let data,
                          let tags = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                        completion(.failure(failure(response: response, error: error)))
                        return
                    }
                    guard !tags.isEmpty else { completion(.success(nil)); return }
                    let versions = tags.compactMap { $0["name"] as? String }.filter(validVersion)
                    guard let name = versions.sorted(by: { isNewer($0, than: $1) }).first else {
                        completion(.failure(CheckError(message: "未找到有效版本标签")))
                        return
                    }
                    completion(.success(Release(version: name, pageURL: URL(string: "https://github.com/\(repo)/releases")!, notes: nil)))
                }
            }
        }
    }
    private static func failure(response: HTTPURLResponse?, error: Error?) -> Error {
        if let error {
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain {
                if ns.code == NSURLErrorTimedOut { return CheckError(message: "连接超时，请重试") }
                if ns.code == NSURLErrorNotConnectedToInternet { return CheckError(message: "网络未连接") }
                return CheckError(message: "无法连接 GitHub（\(ns.code)）")
            }
            return CheckError(message: "网络请求失败")
        }
        switch response?.statusCode {
        case 403, 429: return CheckError(message: "GitHub 请求受限")
        case 404: return CheckError(message: "未找到发布版本")
        case 200: return CheckError(message: "版本响应无效")
        case let code?: return CheckError(message: "GitHub 返回 \(code)")
        case nil: return CheckError(message: "未收到有效响应")
        }
    }
    private static func validVersion(_ value: String) -> Bool {
        value.range(of: "^[vV]?[0-9]+(?:\\.[0-9]+){1,3}$", options: .regularExpression) != nil
    }
    static func parseReleasePage(_ url: URL) -> Release? {
        guard url.scheme == "https", url.host == "github.com", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, url.query == nil, url.fragment == nil else { return nil }
        let prefix = "/\(repo)/releases/tag/"
        guard url.path.hasPrefix(prefix) else { return nil }
        let tag = String(url.path.dropFirst(prefix.count))
        guard validVersion(tag) else { return nil }
        return Release(version: tag, pageURL: url, notes: nil)
    }
    static func parseRelease(_ data: Data) -> Release? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["draft"] as? Bool != true, json["prerelease"] as? Bool != true,
              let tag = json["tag_name"] as? String, validVersion(tag),
              let pageText = json["html_url"] as? String, let page = URL(string: pageText),
              let parsed = parseReleasePage(page), parsed.version == tag else { return nil }
        return Release(version: tag, pageURL: page, notes: json["body"] as? String)
    }
    private static func components(_ version: String) -> [Int] {
        version.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
            .split(separator: ".").map { part in Int(part.prefix(while: { $0.isNumber })) ?? 0 }
    }
    static func isNewer(_ remote: String, than local: String) -> Bool {
        let a = components(remote), b = components(local)
        for i in 0..<max(a.count, b.count) {
            let av = i < a.count ? a[i] : 0, bv = i < b.count ? b[i] : 0
            if av != bv { return av > bv }
        }
        return false
    }
}

func runUpdateFallbackCheck() -> Never {
    var checks = 0
    func require(_ condition: Bool, _ label: String) {
        guard condition else { print("✗ 更新检查：" + label); exit(1) }
        checks += 1
    }
    let page = URL(string: "https://github.com/Visero/mac-kit/releases/tag/v1.2.2")!
    let fixture = Data("{\"tag_name\":\"v1.2.2\",\"html_url\":\"\(page.absoluteString)\"}".utf8)
    func run(_ codes: [Int], _ bodies: [Data?], webURL: URL = page) -> Result<UpdateChecker.Release?, Error> {
        var index = 0
        var result: Result<UpdateChecker.Release?, Error>?
        UpdateChecker.check(transport: { req, completion in
            require(index < codes.count, "不得重复请求")
            require(req.value(forHTTPHeaderField: "Authorization") == nil, "不传令牌")
            let n = index; index += 1
            if req.url?.host == "github.com" { require(req.httpMethod == "HEAD", "公开页只读HEAD") }
            let responseURL = req.url?.host == "github.com" ? webURL : req.url!
            completion(bodies[n], HTTPURLResponse(url: responseURL, statusCode: codes[n], httpVersion: nil, headerFields: nil), nil)
        }, completion: { result = $0 })
        require(index == codes.count && result != nil, "回调必须结束")
        return result!
    }
    if case .success(let release) = run([200], [fixture]) { require(release?.version == "v1.2.2", "API正常") }
    else { require(false, "API正常") }
    for code in [403, 429, 500] {
        if case .success(let release) = run([code, 200], [nil, nil]) { require(release?.pageURL == page, "公开页回退") }
        else { require(false, "公开页回退") }
    }
    if case .failure = run([403, 503], [nil, nil]) { require(true, "双源失败不能报最新") }
    else { require(false, "双源失败") }
    if case .failure = run([200, 200], [Data("bad".utf8), nil], webURL: URL(string: "https://github.com/other/repo/releases/tag/v9.9.9")!) { require(true, "拒绝错误仓库") }
    else { require(false, "错误仓库") }
    if case .success(let release) = run([404, 404, 200], [nil, nil, Data("[]".utf8)]) { require(release == nil, "明确空版本") }
    else { require(false, "空版本") }
    if case .failure = run([404, 404, 403], [nil, nil, nil]) { require(true, "标签受限不报空") }
    else { require(false, "标签受限") }
    require(UpdateChecker.parseReleasePage(URL(string: "https://github.com/Visero/mac-kit/releases/tag/v1.2.2-beta")!) == nil, "拒绝预发布")
    require(UpdateChecker.parseReleasePage(URL(string: "https://github.com.evil.test/Visero/mac-kit/releases/tag/v9.9.9")!) == nil, "拒绝外站")
    var offlineResult: Result<UpdateChecker.Release?, Error>?
    UpdateChecker.check(transport: { _, completion in completion(nil, nil, URLError(.notConnectedToInternet)) }, completion: { offlineResult = $0 })
    if case .failure? = offlineResult { require(true, "离线明确报错") } else { require(false, "离线") }
    print("✓ 更新检查 \(checks) 项断言通过：API、公开发布页回退、限流、离线、坏响应、空版本与来源校验")
    exit(0)
}
