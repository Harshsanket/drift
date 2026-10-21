import SwiftUI

/// Full-pane RSS reader. The server keeps feeds in a tree; Drift shows the
/// flat list of packs it can browse (folders are ignored for now).
///
/// Layout: a fixed feeds rail (like a mail app's folder rail) next to the
/// article list. The pane owns its own header (feeds header left, selected
/// feed header right) and communicates through the shared model.
struct RSSPaneView: View {
    var model: ListViewModel

    @State private var addingFeed = false
    @State private var addFeedURL = ""

    var body: some View {
        HSplitView {
            feedsRail
                .frame(minWidth: 240, maxWidth: 340)

            articlesPane
                .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
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

    // MARK: - Actions

    private func refreshAll() {
        for feed in model.rssFeeds where !feed.hasError {
            model.refreshRSSFeed(feed)
        }
    }

    // MARK: - Feeds rail

    private var feedsRail: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("Feeds")
                    .font(.headline)
                if model.rssContentLoaded {
                    Text("\(model.rssFeeds.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(.quaternary))
                }
                Spacer()

                Button {
                    refreshAll()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .help("Refresh all feeds")
                .disabled(!model.isConnected || model.rssFeeds.isEmpty)

                Button {
                    addingFeed = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderedProminent)
                .help("Add Feed")
                .disabled(!model.isConnected)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            List(selection: Binding(
                get: { model.selectedRSSFeed },
                set: { model.selectRSSFeed($0) }
            )) {
                ForEach(model.rssFeeds) { feed in
                    feedRow(feed)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private func feedRow(_ feed: RSSFeed) -> some View {
        let unread = feed.articles.filter { !$0.isRead }.count
        return HStack(spacing: 8) {
            Image(systemName: "dot.radiowaves.up.forward")
                .font(.caption)
                .foregroundStyle(feed.hasError ? .orange : Color.accentColor)
            Text(feed.name)
                .lineLimit(1)
            Spacer()
            if feed.hasError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help("The feed failed to load")
            } else if unread > 0 {
                Text("\(unread)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(.quaternary))
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

    // MARK: - Articles

    private var articlesPane: some View {
        VStack(spacing: 0) {
            articleHeader
            Divider()

            if let feed = model.selectedRSSFeed {
                articleList(feed)
            } else {
                emptyState
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var articleHeader: some View {
        HStack(spacing: 8) {
            if let feed = model.selectedRSSFeed {
                VStack(alignment: .leading, spacing: 2) {
                    Text(feed.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text("\(feed.articles.count) article\(feed.articles.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Mark All Read") {
                    model.markRSSFeedRead(feed)
                }
                .buttonStyle(.bordered)
                .disabled(feed.articles.allSatisfy(\.isRead))
            } else {
                Text("Feeds")
                    .font(.headline)
                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func articleList(_ feed: RSSFeed) -> some View {
        List {
            ForEach(feed.articles) { article in
                articleRow(article, feed: feed)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .navigationTitle("RSS")
    }

    private func articleRow(_ article: RSSArticle, feed: RSSFeed) -> some View {
        let downloadable = !article.torrentURL.isEmpty || !(article.torrentHash ?? "").isEmpty
        return HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(article.isRead ? AnyShapeStyle(.clear) : AnyShapeStyle(Color.accentColor))
                .frame(width: 8, height: 8)
                .overlay {
                    if article.isRead {
                        Circle().strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1)
                    }
                }
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 3) {
                Text(article.title)
                    .font(.body.weight(article.isRead ? .regular : .semibold))
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if let hash = article.torrentHash {
                        Image(systemName: "arrow.down.circle")
                            .foregroundStyle(.green)
                        Text(hash)
                            .lineLimit(1)
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                    Text(article.date)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()

            if downloadable {
                Button {
                    model.downloadRSSTorrent(article)
                } label: {
                    Image(systemName: "arrow.down.circle")
                        .font(.body)
                }
                .buttonStyle(GhostIconButton())
                .help("Download torrent")
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            if !article.isRead {
                model.markRSSArticleRead(article, in: feed)
            }
        }
        .contextMenu {
            Button("Download") { model.downloadRSSTorrent(article) }
                .disabled(!downloadable)

            if !article.isRead {
                Button("Mark Read") { model.markRSSArticleRead(article, in: feed) }
            }

            Divider()

            Button("Refresh Feed") { model.refreshRSSFeed(feed) }
            Button("Mark All Read") { model.markRSSFeedRead(feed) }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            if model.rssContentLoaded && !model.rssFeeds.isEmpty {
                ContentUnavailableView(
                    "Select a feed",
                    systemImage: "dot.radiowaves.up.forward",
                    description: Text("Pick one on the left to read its articles.")
                )
            } else if model.rssContentLoaded {
                ContentUnavailableView(
                    "No feeds yet",
                    systemImage: "dot.radiowaves.up.forward",
                    description: Text("Add a feed URL to follow its new releases here.")
                )
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private extension Image {
    func monospaced(_ style: Int) -> some View {
        font(.system(.caption, design: .monospaced))
    }
}

private struct GhostIconButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(4)
            .background {
                if configuration.isPressed {
                    RoundedRectangle(cornerRadius: 5).fill(.quaternary)
                }
            }
            .contentShape(Rectangle())
    }
}
