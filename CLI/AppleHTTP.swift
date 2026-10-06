import Foundation

struct AppleHTTPError: LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? { message }
}

func appleRequest(_ request: URLRequest, session: URLSession = .shared) throws -> Data {
    for attempt in 0..<3 {
        let completion = DispatchSemaphore(value: 0)
        var result: Result<(Data, HTTPURLResponse), Error>!
        session.dataTask(with: request) { data, response, error in
            defer { completion.signal() }
            if let error { result = .failure(error); return }
            guard let response = response as? HTTPURLResponse, let data else {
                result = .failure(CommandError(message: "Apple returned no response.")); return
            }
            result = .success((data, response))
        }.resume()
        completion.wait()
        do {
            let (data, response) = try result.get()
            if (200..<300).contains(response.statusCode) { return data }
            if request.httpMethod == "GET", attempt < 2,
               response.statusCode == 429 || (500...599).contains(response.statusCode) {
                let delay = Double(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? Double(2 << attempt)
                Thread.sleep(forTimeInterval: min(30, max(1, delay)))
                continue
            }
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let errors = body?["errors"] as? [[String: Any]] ?? []
            let detail = errors.prefix(3).map { error in
                ["code", "title", "detail"].compactMap { error[$0] as? String }.joined(separator: ": ")
            }.joined(separator: "\n")
            throw AppleHTTPError(status: response.statusCode, message: "Apple \(request.httpMethod ?? "GET") \(request.url?.path ?? ""): HTTP \(response.statusCode)\n\(detail.prefix(1800))")
        } catch let error as URLError where request.httpMethod == "GET" && attempt < 2 && [.timedOut, .networkConnectionLost, .cannotConnectToHost, .notConnectedToInternet].contains(error.code) {
            Thread.sleep(forTimeInterval: Double(2 << attempt))
        }
    }
    throw CommandError(message: "Apple request exhausted its retries.")
}

struct RequiredAction: LocalizedError {
    let result: String
    let message: String
    let command: String
    var errorDescription: String? { message }
}
