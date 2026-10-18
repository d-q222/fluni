import Foundation

/// Fetches the campus model's p_sick.csv from the laptop that serves the heat map.
enum PSickLoader {
    /// The run on main when this was written. Change it in Developer > Demo override; stored under `psickRunID`.
    static let defaultRunID = "influenza_none_n1000_d14_s42_f12e71fa"  // same run the heat map defaults to

    static var runID: String {
        get { UserDefaults.standard.string(forKey: "psickRunID").flatMap { $0.isEmpty ? nil : $0 } ?? defaultRunID }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespaces), forKey: "psickRunID") }
    }

    /// Same scheme, host and port as the saved heat map address; path model/out/<run>/p_sick.csv.
    static func feedURL(heatmapURL: String, runID: String) -> URL? {
        guard let src = URLComponents(string: heatmapURL), let scheme = src.scheme, let host = src.host, !runID.isEmpty else { return nil }
        var c = URLComponents()
        c.scheme = scheme; c.host = host; c.port = src.port
        c.path = "/model/out/\(runID)/p_sick.csv"
        return c.url
    }

    struct Failure: Error { let message: String }

    static func load() async throws -> PSickFeed {
        let saved = UserDefaults.standard.string(forKey: "heatmapURL") ?? ""
        guard let url = feedURL(heatmapURL: saved, runID: runID) else {
            throw Failure(message: "No laptop address yet. Enter the heat map address on the Map tab first.")
        }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        req.httpMethod = "GET"
        let data: Data, resp: URLResponse
        do { (data, resp) = try await URLSession.shared.data(for: req) } catch { throw Failure(message: message(for: error)) }
        if let h = resp as? HTTPURLResponse, h.statusCode != 200 {
            throw Failure(message: h.statusCode == 404
                ? "The laptop doesn't have the model output for run \(runID). Check the run name, or run the model on the laptop."
                : "The laptop answered with an error (\(h.statusCode)).")
        }
        do {
            let feed = try PSickFeed.parse(data)
            if feed.agents.isEmpty { throw Failure(message: "The model output file is empty.") }
            return feed
        } catch let f as Failure { throw f } catch {
            throw Failure(message: "That isn't a model output file, so it was ignored.")
        }
    }

    static func message(for e: Error) -> String {
        switch (e as NSError).code {
        case NSURLErrorNotConnectedToInternet, NSURLErrorDataNotAllowed, NSURLErrorInternationalRoamingOff:
            return "You're offline. Connect to the same Wi-Fi as the laptop."
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return "Couldn't find the laptop. Check its name, or use its IP address in the map address."
        case NSURLErrorTimedOut, NSURLErrorCannotConnectToHost:
            return "Couldn't reach the laptop. Is the server running, and are you on the same Wi-Fi?"
        default:
            return "Couldn't load the campus model: \(e.localizedDescription)"
        }
    }
}
