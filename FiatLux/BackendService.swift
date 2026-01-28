//
//  BackendService.swift
//  FiatLux
//
//  Created by Jeremy Levitt on 1/22/26.
//

import Foundation

/// Service for communicating with the FiatLux backend
class BackendService {
    static let shared = BackendService()

    // TODO: Make this configurable (env var, settings, etc.)
    private let baseURL: String

    init(baseURL: String = "http://localhost:8000") {
        self.baseURL = baseURL
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

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

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

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

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

        let (data, response) = try await URLSession.shared.data(from: url)

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

        let (data, response) = try await URLSession.shared.data(from: url)

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
    }

    /// Check if the backend is running
    func healthCheck() async throws -> HealthResponse {
        guard let url = URL(string: "\(baseURL)/health") else {
            throw BackendError.invalidURL
        }

        let (data, response) = try await URLSession.shared.data(from: url)

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
