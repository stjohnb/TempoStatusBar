import Foundation

struct WorklogResponse: Codable {
    let results: [Worklog]
}

struct Worklog: Codable {
    let dateStarted: String
    let timeSpentSeconds: Int
    let comment: String?
    let issue: WorklogIssue?
    
    var started: String { dateStarted }
}

struct WorklogIssue: Codable {
    let key: String
    let summary: String?
}

struct UserInfo: Codable {
    let accountId: String?
    let name: String?
    let key: String?
    let emailAddress: String?
    
    enum CodingKeys: String, CodingKey {
        case key, name, emailAddress
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decodeIfPresent(String.self, forKey: .key)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        emailAddress = try container.decodeIfPresent(String.self, forKey: .emailAddress)
        accountId = name
    }
}

class TempoService {
    static let shared = TempoService()
    private init() {}
    
    func fetchUserInfo(apiToken: String, jiraURL: String) async throws -> UserInfo? {
        let baseURL = jiraURL.hasSuffix("/") ? jiraURL : jiraURL + "/"
        let urlString = "\(baseURL)rest/api/2/myself"
        
        print("Debug: TempoService - fetchUserInfo URL: \(urlString)")
        
        guard let url = URL(string: urlString) else {
            print("Debug: TempoService - Invalid user info URL: \(urlString)")
            throw TempoError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        do {
            print("Debug: TempoService - Making user info request...")
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                print("Debug: TempoService - Invalid HTTP response for user info")
                throw TempoError.networkError
            }
            
            print("Debug: TempoService - User info HTTP Status Code: \(httpResponse.statusCode)")
            
            if httpResponse.statusCode == 401 {
                print("Debug: TempoService - User info unauthorized")
                throw TempoError.unauthorized
            } else if httpResponse.statusCode == 403 {
                print("Debug: TempoService - User info forbidden")
                throw TempoError.forbidden
            } else if httpResponse.statusCode != 200 {
                print("Debug: TempoService - User info API error: \(httpResponse.statusCode)")
                throw TempoError.apiError(statusCode: httpResponse.statusCode)
            }
            
            print("Debug: TempoService - User info response data length: \(data.count)")
            if let responseString = String(data: data, encoding: .utf8) {
                print("Debug: TempoService - User info response: \(responseString.prefix(300))...")
            }
            
            let userInfo = try JSONDecoder().decode(UserInfo.self, from: data)
            print("Debug: TempoService - Decoded user info: \(userInfo.name ?? "nil") / \(userInfo.key ?? "nil")")
            return userInfo
        } catch {
            print("Debug: TempoService - User info network error: \(error)")
            throw TempoError.networkError
        }
    }
    
    func fetchLatestWorklog(apiToken: String, jiraURL: String, accountId: String? = nil) async throws -> Worklog? {
        print("Debug: TempoService - Starting fetchLatestWorklog")
        
        let userInfo = try await fetchUserInfo(apiToken: apiToken, jiraURL: jiraURL)
        print("Debug: TempoService - User info: \(userInfo?.name ?? "nil") / \(userInfo?.key ?? "nil")")
        
        let identifier = accountId?.isEmpty == false ? accountId! : userInfo?.name ?? userInfo?.key ?? ""
        print("Debug: TempoService - Using identifier: \(identifier)")
        
        guard !identifier.isEmpty else {
            print("Debug: TempoService - Empty identifier, throwing missingCredentials")
            throw TempoError.missingCredentials
        }
        
        print("Debug: TempoService - Fetching worklog for identifier: \(identifier)")
        return try await fetchWorklog(apiToken: apiToken, jiraURL: jiraURL, identifier: identifier)
    }
    
    func getDaysSinceLastWorklog(apiToken: String, jiraURL: String, accountId: String? = nil) async -> Int? {
        do {
            print("Debug: TempoService - Starting getDaysSinceLastWorklog")
            print("Debug: TempoService - API Token: \(apiToken.prefix(10))...")
            print("Debug: TempoService - Jira URL: \(jiraURL)")
            print("Debug: TempoService - Account ID: \(accountId ?? "nil")")
            
            guard let worklog = try await fetchLatestWorklog(apiToken: apiToken, jiraURL: jiraURL, accountId: accountId) else {
                print("Debug: TempoService - No worklog found")
                return nil
            }
            
            print("Debug: TempoService - Found worklog with date: \(worklog.started)")
            
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
            
            guard let worklogDate = dateFormatter.date(from: worklog.started) else {
                print("Debug: TempoService - Failed to parse worklog date: \(worklog.started)")
                return nil
            }
            
            let calendar = Calendar.current
            let days = calendar.dateComponents([.day], from: worklogDate, to: Date()).day ?? 0
            print("Debug: TempoService - Calculated days since last worklog: \(days)")
            return days
        } catch {
            print("Debug: TempoService - Error in getDaysSinceLastWorklog: \(error)")
            return nil
        }
    }
    
    func testConnection(apiToken: String, accountId: String, jiraURL: String) async throws -> Worklog? {
        let userIdentifier = accountId.isEmpty ? 
            (try await fetchUserInfo(apiToken: apiToken, jiraURL: jiraURL))?.name ?? "" : accountId
        
        guard !userIdentifier.isEmpty else {
            throw TempoError.missingCredentials
        }
        
        return try await fetchWorklog(apiToken: apiToken, jiraURL: jiraURL, identifier: userIdentifier)
    }
    
    private func fetchWorklog(apiToken: String, jiraURL: String, identifier: String) async throws -> Worklog? {
        let baseURL = jiraURL.hasSuffix("/") ? jiraURL : jiraURL + "/"
        let urlString = "\(baseURL)rest/tempo-timesheets/3/worklogs"
        
        print("Debug: TempoService - fetchWorklog URL: \(urlString)")
        
        guard let url = URL(string: urlString) else {
            print("Debug: TempoService - Invalid URL: \(urlString)")
            throw TempoError.invalidURL
        }
        
        let calendar = Calendar.current
        let endDate = Date()
        let startDate = calendar.date(byAdding: .day, value: -60, to: endDate) ?? endDate
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        
        var urlComponents = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        urlComponents.queryItems = [
            URLQueryItem(name: "username", value: identifier),
            URLQueryItem(name: "dateFrom", value: dateFormatter.string(from: startDate)),
            URLQueryItem(name: "dateTo", value: dateFormatter.string(from: endDate))
        ]
        
        guard let finalURL = urlComponents.url else {
            print("Debug: TempoService - Failed to create final URL")
            throw TempoError.invalidURL
        }
        
        print("Debug: TempoService - Final URL: \(finalURL)")
        print("Debug: TempoService - Date range: \(dateFormatter.string(from: startDate)) to \(dateFormatter.string(from: endDate))")
        
        var request = URLRequest(url: finalURL)
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        do {
            print("Debug: TempoService - Making API request...")
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                print("Debug: TempoService - Invalid HTTP response")
                throw TempoError.networkError
            }
            
            print("Debug: TempoService - HTTP Status Code: \(httpResponse.statusCode)")
            
            if httpResponse.statusCode == 401 {
                print("Debug: TempoService - Unauthorized")
                throw TempoError.unauthorized
            } else if httpResponse.statusCode == 403 {
                print("Debug: TempoService - Forbidden")
                throw TempoError.forbidden
            } else if httpResponse.statusCode != 200 {
                print("Debug: TempoService - API Error: \(httpResponse.statusCode)")
                throw TempoError.apiError(statusCode: httpResponse.statusCode)
            }
            
            print("Debug: TempoService - Response data length: \(data.count)")
            
            do {
                let worklogs = try JSONDecoder().decode([Worklog].self, from: data)
                print("Debug: TempoService - Decoded \(worklogs.count) worklogs directly")
                return getMostRecentWorklog(worklogs)
            } catch {
                print("Debug: TempoService - Direct decode failed, trying WorklogResponse: \(error)")
                let worklogResponse = try JSONDecoder().decode(WorklogResponse.self, from: data)
                print("Debug: TempoService - Decoded \(worklogResponse.results.count) worklogs from response")
                return getMostRecentWorklog(worklogResponse.results)
            }
        } catch let error as TempoError {
            print("Debug: TempoService - TempoError thrown: \(error)")
            throw error
        } catch {
            print("Debug: TempoService - Network error: \(error)")
            throw TempoError.networkError
        }
    }
    
    private func getMostRecentWorklog(_ worklogs: [Worklog]) -> Worklog? {
        guard !worklogs.isEmpty else { return nil }
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        
        return worklogs.max { worklog1, worklog2 in
            guard let date1 = dateFormatter.date(from: worklog1.started),
                  let date2 = dateFormatter.date(from: worklog2.started) else {
                return false
            }
            return date1 < date2
        }
    }
}

enum TempoError: Error, LocalizedError {
    case missingCredentials
    case invalidURL
    case unauthorized
    case forbidden
    case notFound
    case networkError
    case apiError(statusCode: Int)
    
    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return "Missing API credentials"
        case .invalidURL:
            return "Invalid Jira URL"
        case .unauthorized:
            return "Unauthorized - check your API token"
        case .forbidden:
            return "Forbidden - check your account permissions"
        case .notFound:
            return "Account not found - check your Account ID"
        case .networkError:
            return "Network error - check your internet connection"
        case .apiError(let statusCode):
            return "API error (HTTP \(statusCode))"
        }
    }
}
