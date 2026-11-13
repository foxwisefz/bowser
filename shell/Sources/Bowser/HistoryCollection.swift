import AppKit
import SwiftUI
import BowserSurfaceKit

/// AppKit owns document sizing and reuse. SwiftUI renders only fixed-size cards
/// and headers, so shrinking a scrolled search cannot re-enter a lazy layout.
@MainActor struct HistoryCollection: NSViewRepresentable {
    let sessions: [HistorySession]
    let selection: Set<String>
    let collapsed: Set<String>
    let showTopics: Bool
    let showProfiles: Bool
    let hasMore: Bool
    let searchIdentity: [String]
    let card: (HistorySearchItem) -> AnyView
    let header: (HistorySession) -> AnyView
    let footer: () -> AnyView

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = HistoryCollectionScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let collection = NSCollectionView()
        collection.wantsLayer = true
        collection.backgroundColors = [.windowBackgroundColor]
        collection.isSelectable = false
        let layout = HistoryCollectionLayout()
        collection.collectionViewLayout = layout
        collection.register(HistoryCollectionItem.self, forItemWithIdentifier: Coordinator.itemID)
        collection.register(HistoryCollectionItem.self, forItemWithIdentifier: Coordinator.headerID)
        collection.register(HistoryCollectionItem.self, forItemWithIdentifier: Coordinator.footerID)
        collection.dataSource = context.coordinator
        scroll.documentView = collection
        return scroll
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.bounds.width, height: proposal.height ?? nsView.bounds.height)
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let collection = scroll.documentView as? NSCollectionView else { return }
        context.coordinator.update(self, in: collection)
    }

    @MainActor final class Coordinator: NSObject, NSCollectionViewDataSource {
        static let itemID = NSUserInterfaceItemIdentifier("history-card")
        static let headerID = NSUserInterfaceItemIdentifier("history-session")
        static let footerID = NSUserInterfaceItemIdentifier("history-more")
        var parent: HistoryCollection
        private var items: [HistorySearchItem]?
        init(_ parent: HistoryCollection) { self.parent = parent }

        func update(_ next: HistoryCollection, in collection: NSCollectionView) {
            let nextItems = next.sessions.flatMap(\.items)
            let resetScroll = parent.searchIdentity != next.searchIdentity
            let reload = items != nextItems || parent.collapsed != next.collapsed
                || parent.showTopics != next.showTopics || parent.showProfiles != next.showProfiles
                || parent.hasMore != next.hasMore
            let selectionChanged = parent.selection != next.selection
            parent = next
            if reload {
                items = nextItems
                (collection.collectionViewLayout as? HistoryCollectionLayout)?.sections = next.sessions.enumerated().map { section, session in
                    HistoryCollectionLayout.Section(
                        cards: cardCount(section),
                        headerHeight: 24 + (next.showTopics ? 28 : 0) + (session.isVisit ? 0 : 26),
                        cardHeight: next.showProfiles ? 224 : 204,
                        footer: hasFooter(section))
                }
                collection.reloadData()
                collection.collectionViewLayout?.invalidateLayout()
            } else if selectionChanged {
                for cell in collection.visibleItems() {
                    guard let index = collection.indexPath(for: cell), let cell = cell as? HistoryCollectionItem else { continue }
                    cell.host.rootView = content(at: index)
                }
            }
            if resetScroll, let scroll = collection.enclosingScrollView {
                scroll.contentView.scroll(to: .zero)
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }

        func numberOfSections(in collectionView: NSCollectionView) -> Int { parent.sessions.count }
        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
            let session = parent.sessions[section]
            return 1 + (parent.collapsed.contains(session.id) ? 0 : session.items.count) + (hasFooter(section) ? 1 : 0)
        }
        private func hasFooter(_ section: Int) -> Bool { parent.hasMore && section == parent.sessions.count - 1 }
        private func cardCount(_ section: Int) -> Int {
            let session = parent.sessions[section]
            return parent.collapsed.contains(session.id) ? 0 : session.items.count
        }
        private func content(at index: IndexPath) -> AnyView {
            if index.item == 0 { return parent.header(parent.sessions[index.section]) }
            if index.item > cardCount(index.section) { return parent.footer() }
            return parent.card(parent.sessions[index.section].items[index.item - 1])
        }
        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            // Full-width header/footer items share the same recycling path as
            // cards. Supplementary SwiftUI headers leave stale drawing behind
            // when a scrolled collection is filtered in the browser tab host.
            let id = indexPath.item == 0 ? Self.headerID : indexPath.item > cardCount(indexPath.section) ? Self.footerID : Self.itemID
            let cell = collectionView.makeItem(withIdentifier: id, for: indexPath) as! HistoryCollectionItem
            cell.host.rootView = content(at: indexPath)
            return cell
        }
    }
}

@MainActor private final class HistoryCollectionScrollView: NSScrollView {
    private var layoutWidth: CGFloat = -1
    override func tile() {
        super.tile()
        guard let collection = documentView as? NSCollectionView else { return }
        let width = contentSize.width
        guard abs(layoutWidth - width) > 0.5 else { return }
        layoutWidth = width
        collection.setFrameSize(NSSize(width: width, height: collection.frame.height))
        collection.collectionViewLayout?.invalidateLayout()
    }
}

@MainActor private final class HistoryCollectionLayout: NSCollectionViewLayout {
    struct Section {
        let cards: Int
        let headerHeight: CGFloat
        let cardHeight: CGFloat
        let footer: Bool
    }
    var sections: [Section] = []
    private var attributes: [IndexPath: NSCollectionViewLayoutAttributes] = [:]
    private var ordered: [NSCollectionViewLayoutAttributes] = []
    private var size: NSSize = .zero

    override func prepare() {
        super.prepare()
        guard let collection = collectionView else { return }
        let width = collection.enclosingScrollView?.contentSize.width ?? collection.bounds.width
        guard width > 0 else { attributes = [:]; ordered = []; size = .zero; return }
        let columns = max(1, Int((width + 16) / 191))
        let cardWidth = min(320, (width - CGFloat(columns - 1) * 16) / CGFloat(columns))
        var y: CGFloat = 12
        attributes = [:]; ordered = []
        func add(_ section: Int, _ item: Int, _ frame: NSRect) {
            let path = IndexPath(item: item, section: section)
            let value = NSCollectionViewLayoutAttributes(forItemWith: path)
            value.frame = frame
            attributes[path] = value; ordered.append(value)
        }
        for (section, info) in sections.enumerated() {
            add(section, 0, NSRect(x: 0, y: y, width: width, height: info.headerHeight))
            y += info.headerHeight + 18
            for item in 0..<info.cards {
                add(section, item + 1, NSRect(
                    x: CGFloat(item % columns) * (cardWidth + 16),
                    y: y + CGFloat(item / columns) * (info.cardHeight + 18),
                    width: cardWidth, height: info.cardHeight))
            }
            y += CGFloat((info.cards + columns - 1) / columns) * (info.cardHeight + 18)
            if info.footer {
                add(section, info.cards + 1, NSRect(x: 0, y: y, width: width, height: 44))
                y += 62
            }
            y += 26
        }
        size = NSSize(width: width, height: y)
    }
    override var collectionViewContentSize: NSSize { size }
    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        ordered.filter { $0.frame.intersects(rect) }
    }
    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? { attributes[indexPath] }
    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        abs(newBounds.width - size.width) > 0.5
    }
}

@MainActor private final class HistoryCollectionItem: NSCollectionViewItem {
    let host = NSHostingView(rootView: AnyView(EmptyView()))
    override func loadView() { host.sizingOptions = []; view = host }
    override func prepareForReuse() { super.prepareForReuse(); host.rootView = AnyView(EmptyView()) }
}

