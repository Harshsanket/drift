import SwiftUI

/// Full-pane RSS reader. The server keeps feeds in a tree; Drift shows the
/// flat list of packs it can browse (folders are ignored for now).
struct RSSPaneView: View {
    var model: ListViewModel

    @State private var addingFeed = false
    @State private var addFeedURL = ""

    var body: some View {
        HSplitView {
            feedsColumn
                .frame(minWidth: 220, maxWidth: 320)

            List {
                if let feed = model.selectedRSSFeed {
                    ForEach(feed.articles) { article in
                        articleRow(article, feed: feed)
                    }
                } else if model.rssContentLoaded {
                    Text("Select a feed.")
                        .foregroundStyle(.secondary)
                } else if model.rssFeeds.isEmpty {
                    Text("No feeds yet.")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("RSS")
            .frame(minWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert("Add Feed", isPresented: $addingFeed) {
            TextField("Feed URL", text: $addFeedURL)
            Button("Add") {
                model.addRSSFeed(url: addFeedURL)
                addFeedURL = ""
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Subscribe to an RSS feed on the server.")
        }
    }

    private var feedsColumn: some View {
        List(selection: Binding(
            get: { model.selectedRSSFeed },
            set: { model.selectRSSFeed($0) }
        )) {
            Section("Feeds") {
                ForEach(model.rssFeeds) { feed in
                    HStack {
                        Text(feed.name)
                            .lineLimit(1)
                        Spacer()
                        if feed.hasError {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        } else {
                            Text("\(feed.articles.count)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contextMenu {
                        Button("Refresh Feed") { model.refreshRSSFeed(feed) }
                        Button("Mark All Read") { model.markRSSFeedRead(feed) }
                        Divider()
                        Button("Remove Feed", role: .destructive) {
                            model.removeRSSFeed(feed)
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button {
                    addingFeed = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.bordered)
                .help("Add Feed")
                .disabled(!model.isConnected)

                Spacer()
            }
            .padding(6)
        }
    }

    private func articleRow(_ article: RSSArticle, feed: RSSFeed) -> some View {
        HStack(alignment: .top) {
            Circle()
                .fill(article.isRead ? Color.clear : Color.accentColor)
                .frame(width: 7, height: 7)
                .overlay {
                    if article.isRead {
                        Circle().strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1)
                    }
                }
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(article.title)
                    .font(.body)
                    .lineLimit(2)
                Text(article.date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if !article.isRead {
                model.markRSSArticleRead(article, in: feed)
            }
        }
        .contextMenu {
            Button("Download") { model.downloadRSSTorrent(article) }
            .disabled(article.torrentURL.isEmpty && (article.torrentHash ?? "").isEmpty)

            if !article.isRead {
                Button("Mark Read") { model.markRSSArticleRead(article, in: feed) }
            }

            Divider()

            Button("Refresh Feed") { model.refreshRSSFeed(feed) }
            Button("Mark All Read") { model.markRSSFeedRead(feed) }
        }
    }
}
