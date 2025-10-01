//
//  ContentView.swift
//  ScheduleAI
//
//  Created by Tai Wong on 10/1/25.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var engine: Engine

    var body: some View {
        TabView {
            LibraryView()
                .tabItem {
                    Label("Library", systemImage: "books.vertical")
                }

            SearchView()
                .tabItem {
                    Label("Search", systemImage: "magnifyingglass")
                }

            ChatPlaceholderView()
                .tabItem {
                    Label("Chat", systemImage: "bubble.left.and.bubble.right")
                }
        }
        .environmentObject(engine)
    }
}

private struct ChatPlaceholderView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.exclamationmark.bubble.right")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Chat is coming soon")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Import PDFs and run BM25 search today. We'll wire Llama-powered chat in the next phase.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

#Preview {
    ContentView()
        .environmentObject(Engine.preview)
}
