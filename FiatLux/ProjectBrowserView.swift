//
//  ProjectBrowserView.swift
//  FiatLux
//
//  Created by Claude on 1/28/26.
//

import SwiftUI

/// View for browsing and selecting existing projects
struct ProjectBrowserView: View {
    @Environment(\.dismiss) private var dismiss

    let onSelect: (BackendService.Project) -> Void

    @State private var projects: [BackendService.Project] = []
    @State private var isLoading = true
    @State private var error: String?
    @State private var searchText = ""

    private var filteredProjects: [BackendService.Project] {
        if searchText.isEmpty {
            return projects
        }
        return projects.filter { project in
            project.name.localizedCaseInsensitiveContains(searchText) ||
            project.project_id.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Select Project")
                    .font(.headline)
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding()

            Divider()

            // Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search projects...", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(8)
            .padding(.horizontal)
            .padding(.vertical, 8)

            // Content
            if isLoading {
                Spacer()
                ProgressView("Loading projects...")
                Spacer()
            } else if let error = error {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.orange)
                    Text(error)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Retry") {
                        loadProjects()
                    }
                }
                .padding()
                Spacer()
            } else if filteredProjects.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "folder")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text(searchText.isEmpty ? "No projects found" : "No matching projects")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredProjects) { project in
                            ProjectRow(project: project) {
                                onSelect(project)
                                dismiss()
                            }
                            Divider()
                                .padding(.leading, 56)
                        }
                    }
                }
            }
        }
        .frame(minWidth: 300, minHeight: 400)
        .onAppear {
            loadProjects()
        }
    }

    private func loadProjects() {
        isLoading = true
        error = nil

        Task {
            do {
                let result = try await BackendService.shared.listProjects()
                await MainActor.run {
                    projects = result
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }
}

struct ProjectRow: View {
    let project: BackendService.Project
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.orange.opacity(0.2))
                        .frame(width: 40, height: 40)
                    Image(systemName: "folder.fill")
                        .foregroundStyle(.orange)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name)
                        .font(.body)
                        .foregroundStyle(.primary)
                    Text("\(project.file_count) files")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    ProjectBrowserView { project in
        print("Selected: \(project.name)")
    }
}
