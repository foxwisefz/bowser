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
        // Recycled supplementary views need their own compositing surface in
        // the browser's layered tab host. Clear backing leaves retired header
        // pixels visible after scrolling or replacing search results.
        collection.wantsLayer = true
        collection.backgroundColors = [.windowBackgroundColor]
        collection.isSelectable = false
        let layout = HistoryCollectionLayout()
        layout.minimumInteritemSpacing = 16
        layout.minimumLineSpacing = 18
        layout.sectionInset = NSEdgeInsets(top: 12, left: 0, bottom: 26, right: 0)
        collection.collectionViewLayout = layout
        collection.register(HistoryCollectionItem.self, forItemWithIdentifier: Coordinator.itemID)
        collection.register(HistoryCollectionSupplement.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader, withIdentifier: Coordinator.headerID)
        collection.register(HistoryCollectionSupplement.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionFooter, withIdentifier: Coordinator.footerID)
        collection.dataSource = context.coordinator
        collection.delegate = context.coordinator
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

    @MainActor final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout {
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
                collection.reloadData()
                collection.collectionViewLayout?.invalidateLayout()
            } else if selectionChanged {
                for cell in collection.visibleItems() {
                    guard let index = collection.indexPath(for: cell), let cell = cell as? HistoryCollectionItem else { continue }
                    cell.host.rootView = parent.card(parent.sessions[index.section].items[index.item])
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
            return parent.collapsed.contains(session.id) ? 0 : session.items.count
        }
        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let cell = collectionView.makeItem(withIdentifier: Self.itemID, for: indexPath) as! HistoryCollectionItem
            cell.host.rootView = parent.card(parent.sessions[indexPath.section].items[indexPath.item])
            return cell
        }
        func collectionView(_ collectionView: NSCollectionView, viewForSupplementaryElementOfKind kind: String, at indexPath: IndexPath) -> NSView {
            let isHeader = kind == NSCollectionView.elementKindSectionHeader
            let view = collectionView.makeSupplementaryView(ofKind: kind, withIdentifier: isHeader ? Self.headerID : Self.footerID, for: indexPath) as! HistoryCollectionSupplement
            view.rootView = isHeader ? parent.header(parent.sessions[indexPath.section]) : parent.footer()
            return view
        }
        func collectionView(_ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> NSSize {
            let width = collectionView.enclosingScrollView?.contentSize.width ?? collectionView.bounds.width
            let columns = max(1, Int((width + 16) / 191))
            return NSSize(width: min(320, max(1, (width - CGFloat(columns - 1) * 16) / CGFloat(columns))), height: parent.showProfiles ? 224 : 204)
        }
        func collectionView(_ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout, referenceSizeForHeaderInSection section: Int) -> NSSize {
            NSSize(width: collectionView.bounds.width, height: 24 + (parent.showTopics ? 28 : 0) + (parent.sessions[section].isVisit ? 0 : 26))
        }
        func collectionView(_ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout, referenceSizeForFooterInSection section: Int) -> NSSize {
            NSSize(width: collectionView.bounds.width, height: parent.hasMore && section == parent.sessions.count - 1 ? 44 : 0)
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

@MainActor private final class HistoryCollectionLayout: NSCollectionViewFlowLayout {
    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        abs(newBounds.width - (collectionView?.bounds.width ?? 0)) > 0.5
    }
}

@MainActor private final class HistoryCollectionItem: NSCollectionViewItem {
    let host = NSHostingView(rootView: AnyView(EmptyView()))
    override func loadView() { host.sizingOptions = []; view = host }
    override func prepareForReuse() { super.prepareForReuse(); host.rootView = AnyView(EmptyView()) }
}

@MainActor private final class HistoryCollectionSupplement: NSHostingView<AnyView>, NSCollectionViewElement {
    @objc init(frame: NSRect) {
        super.init(rootView: AnyView(EmptyView()))
        self.frame = frame
        sizingOptions = []
    }
    required init(rootView: AnyView) { super.init(rootView: rootView); sizingOptions = [] }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func prepareForReuse() { super.prepareForReuse(); rootView = AnyView(EmptyView()) }
}
