//
//  SearchView.swift
//  Music
//

import SwiftUI

struct SearchView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            List {
                if searchText.isEmpty {
                    ContentUnavailableView(
                        "Search Music",
                        systemImage: "magnifyingglass",
                        description: Text("Search for artists, albums, or songs")
                    )
                } else {
                    // Placeholder sections for search results
                    Section("Artists") {
                        Text("No artists found")
                            .foregroundStyle(.secondary)
                    }

                    Section("Albums") {
                        Text("No albums found")
                            .foregroundStyle(.secondary)
                    }

                    Section("Songs") {
                        Text("No songs found")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Artists, Albums, Songs")
            .navigationTitle("Search")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

#Preview {
    SearchView()
}
