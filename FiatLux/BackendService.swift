//
//  BackendService.swift
//  FiatLux
//
//  Created by Jeremy Levitt on 1/22/26.
//

import Foundation

/// Environment configuration for the backend
enum BackendEnvironment {
    case local
    case dev
    case prod

    var baseURL: String {
        switch self {
        case .local:
            return "http://localhost:8000"
        case .dev:
            // Update this after running deploy.sh
            return "https://nklv393x7j.execute-api.us-west-1.amazonaws.com/dev"
        case .prod:
            return "https://nklv393x7j.execute-api.us-west-1.amazonaws.com/dev"
        }
    }

    var requiresApiKey: Bool {
        switch self {
        case .local:
            return false
        case .dev, .prod:
            return false  // HTTP API v2 doesn't use API keys by default
        }
    }
}

/// Service for communicating with the FiatLux backend
class BackendService {
    static var shared = BackendService(environment: .dev)  // Use AWS by default

    private let environment: BackendEnvironment
    private let apiKey: String?
    private let authToken: String?
    let baseURL: String  // Accessible for AuthManager

    init(environment: BackendEnvironment = .local, apiKey: String? = nil, authToken: String? = nil) {
        self.environment = environment
        self.apiKey = apiKey
        self.authToken = authToken
        self.baseURL = environment.baseURL
    }

    /// Create a configured URLRequest with common headers
    private func makeRequest(url: URL, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if environment.requiresApiKey, let key = apiKey {
            request.setValue(key, forHTTPHeaderField: "x-api-key")
        }

        // Add auth token for authenticated requests
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        return request
    }

    // MARK: - Upload

    struct UploadResponse: Codable {
        let success: Bool
        let file_id: String
        let path: String
        let size: Int
    }

    /// Upload a PDF to the backend's raw/ folder
    /// - Parameters:
    ///   - pdfData: The PDF file contents
    ///   - path: Path under raw/, e.g., "MyNotes/note1.pdf"
    /// - Returns: UploadResponse with file details
    func uploadPDF(data: Data, path: String) async throws -> UploadResponse {
        guard let url = URL(string: "\(baseURL)/upload") else {
            throw BackendError.invalidURL
        }

        var request = makeRequest(url: url, method: "POST")

        let body: [String: Any] = [
            "path": path,
            "content_base64": data.base64EncodedString(),
            "mime_type": "application/pdf"
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (responseData, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw BackendError.invalidResponse
        }

        if httpResponse.statusCode != 200 {
            // Try to parse error message
            if let errorDict = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
               let detail = errorDict["detail"] as? String {
                throw BackendError.serverError(detail)
            }
            throw BackendError.httpError(httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        return try decoder.decode(UploadResponse.self, from: responseData)
    }

    // MARK: - Jobs

    struct JobResponse: Codable {
        let job_id: String
        let status: String
        let message: String?
    }

    struct JobStatusResponse: Codable {
        let job_id: String
        let job_type: String
        let status: String
        let raw_file_path: String
        let output_path: String?
        let result: [String: AnyCodable]?
        let error: String?
        let created_at: String
        let completed_at: String?
    }

    /// Submit a job for processing
    func submitJob(jobType: String, rawFilePath: String, projectId: String? = nil) async throws -> JobResponse {
        guard let url = URL(string: "\(baseURL)/jobs") else {
            throw BackendError.invalidURL
        }

        var request = makeRequest(url: url, method: "POST")

        var body: [String: Any] = [
            "job_type": jobType,
            "raw_file_path": rawFilePath
        ]

        if let projectId = projectId {
            body["project_id"] = projectId
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (responseData, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw BackendError.invalidResponse
        }

        if httpResponse.statusCode != 200 {
            if let errorDict = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
               let detail = errorDict["detail"] as? String {
                throw BackendError.serverError(detail)
            }
            throw BackendError.httpError(httpResponse.statusCode)
        }

        return try JSONDecoder().decode(JobResponse.self, from: responseData)
    }

    /// Get job status
    func getJob(jobId: String) async throws -> JobStatusResponse {
        guard let url = URL(string: "\(baseURL)/jobs/\(jobId)") else {
            throw BackendError.invalidURL
        }

        let request = makeRequest(url: url)
        let (responseData, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw BackendError.invalidResponse
        }

        if httpResponse.statusCode == 404 {
            throw BackendError.serverError("Job not found")
        }

        if httpResponse.statusCode != 200 {
            if let errorDict = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
               let detail = errorDict["detail"] as? String {
                throw BackendError.serverError(detail)
            }
            throw BackendError.httpError(httpResponse.statusCode)
        }

        return try JSONDecoder().decode(JobStatusResponse.self, from: responseData)
    }

    /// Wait for job completion with polling
    /// NOTE: Uses BackendService.shared on each iteration to pick up refreshed tokens
    func waitForJob(jobId: String, pollInterval: TimeInterval = 2.0, timeout: TimeInterval = 300) async throws -> JobStatusResponse {
        let startTime = Date()
        var retryCount = 0
        let maxRetries = 3

        while true {
            do {
                // Use .shared to get the latest instance with refreshed token
                let job = try await BackendService.shared.getJob(jobId: jobId)
                retryCount = 0  // Reset on success

                if job.status == "completed" || job.status == "failed" {
                    return job
                }

                if Date().timeIntervalSince(startTime) > timeout {
                    throw BackendError.serverError("Job timed out")
                }

                try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            } catch BackendError.httpError(401) {
                // Token expired - trigger refresh and retry
                retryCount += 1
                if retryCount > maxRetries {
                    throw BackendError.httpError(401)
                }
                print("[BackendService] Got 401, refreshing token (attempt \(retryCount)/\(maxRetries))")
                await AuthManager.shared.refreshToken()
                try await Task.sleep(nanoseconds: 500_000_000)  // Wait 0.5s for refresh
            }
        }
    }

    // MARK: - Execute

    struct ExecuteResponse: Codable {
        let jobId: String
        let status: String

        enum CodingKeys: String, CodingKey {
            case jobId = "job_id"
            case status
        }
    }

    /// Execute AI processing on an uploaded file
    /// - Parameters:
    ///   - filePath: Path to the uploaded file (from upload response)
    ///   - projectName: Optional project name to associate with
    /// - Returns: ExecuteResponse with job ID
    func execute(filePath: String, projectName: String?) async throws -> ExecuteResponse {
        guard let url = URL(string: "\(baseURL)/execute") else {
            throw BackendError.invalidURL
        }

        var request = makeRequest(url: url, method: "POST")

        var body: [String: Any] = [
            "file_path": filePath
        ]

        if let projectName = projectName {
            body["project_name"] = projectName
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (responseData, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw BackendError.invalidResponse
        }

        if httpResponse.statusCode != 200 {
            if let errorDict = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
               let detail = errorDict["detail"] as? String {
                throw BackendError.serverError(detail)
            }
            throw BackendError.httpError(httpResponse.statusCode)
        }

        return try JSONDecoder().decode(ExecuteResponse.self, from: responseData)
    }

    // MARK: - Trigger

    struct TriggerResponse: Codable {
        let triggered: Bool
        let job: JobInfo?

        struct JobInfo: Codable {
            let job_id: String
            let status: String
            let message: String
        }
    }

    /// Trigger processing for an uploaded file
    /// - Parameters:
    ///   - filePath: Full path including raw/, e.g., "raw/Notes/my_note.pdf"
    ///   - projectId: Optional project ID for existing_project mode
    /// - Returns: TriggerResponse with job info, or nil if trigger endpoint not available
    func trigger(filePath: String, projectId: String? = nil) async -> TriggerResponse? {
        guard let url = URL(string: "\(baseURL)/trigger") else {
            return nil
        }

        var request = makeRequest(url: url, method: "POST")

        var body: [String: Any] = [
            "file_path": filePath
        ]

        if let projectId = projectId {
            body["project_id"] = projectId
        }

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (responseData, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                // Trigger endpoint not available or error - that's OK
                return nil
            }

            return try JSONDecoder().decode(TriggerResponse.self, from: responseData)
        } catch {
            // Trigger failed - that's OK, upload still succeeded
            print("Trigger failed (non-fatal): \(error)")
            return nil
        }
    }

    // MARK: - Projects

    struct Project: Codable, Identifiable {
        let project_id: String
        let name: String
        let file_count: Int
        let last_modified: String?

        var id: String { project_id }
    }

    struct ProjectListResponse: Codable {
        let projects: [Project]
    }

    struct ProjectFile: Codable, Identifiable {
        let id: String
        let name: String
        let path: String
        let mime_type: String?
        let size: Int?
    }

    struct ProjectFilesResponse: Codable {
        let project_id: String
        let files: [ProjectFile]
    }

    /// List all available projects from storage
    /// - Parameter search: Optional search query to filter by name
    /// - Returns: List of projects
    func listProjects(search: String? = nil) async throws -> [Project] {
        var components = URLComponents(string: "\(baseURL)/projects")
        if let search = search, !search.isEmpty {
            components?.queryItems = [URLQueryItem(name: "search", value: search)]
        }

        guard let url = components?.url else {
            throw BackendError.invalidURL
        }

        let request = makeRequest(url: url)
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw BackendError.invalidResponse
        }

        if httpResponse.statusCode != 200 {
            if let errorDict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let detail = errorDict["detail"] as? String {
                throw BackendError.serverError(detail)
            }
            throw BackendError.httpError(httpResponse.statusCode)
        }

        let result = try JSONDecoder().decode(ProjectListResponse.self, from: data)
        return result.projects
    }

    /// Get files in a specific project
    /// - Parameter projectId: The project identifier
    /// - Returns: List of files in the project
    func getProjectFiles(projectId: String) async throws -> [ProjectFile] {
        guard let url = URL(string: "\(baseURL)/projects/\(projectId)/files") else {
            throw BackendError.invalidURL
        }

        let request = makeRequest(url: url)
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw BackendError.invalidResponse
        }

        if httpResponse.statusCode != 200 {
            if let errorDict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let detail = errorDict["detail"] as? String {
                throw BackendError.serverError(detail)
            }
            throw BackendError.httpError(httpResponse.statusCode)
        }

        let result = try JSONDecoder().decode(ProjectFilesResponse.self, from: data)
        return result.files
    }

    // MARK: - Health Check

    struct HealthResponse: Codable {
        let status: String
        let storage: String
        let bucket: String?
        let region: String?
    }

    /// Check if the backend is running
    func healthCheck() async throws -> HealthResponse {
        guard let url = URL(string: "\(baseURL)/health") else {
            throw BackendError.invalidURL
        }

        let request = makeRequest(url: url)
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw BackendError.invalidResponse
        }

        return try JSONDecoder().decode(HealthResponse.self, from: data)
    }
}

// MARK: - Errors

enum BackendError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(Int)
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid backend URL"
        case .invalidResponse:
            return "Invalid response from backend"
        case .httpError(let code):
            return "HTTP error: \(code)"
        case .serverError(let message):
            return message
        }
    }
}

// MARK: - AnyCodable helper for dynamic JSON

struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else {
            value = NSNull()
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch value {
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            try container.encodeNil()
        }
    }
}
