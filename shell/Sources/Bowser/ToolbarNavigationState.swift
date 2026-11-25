/// The active page's navigation controls, shared with the replaceable toolbar.
struct ToolbarNavigationState: Decodable, Equatable {
    let canGoBack: Bool
    let canGoForward: Bool
    let canReload: Bool
    let isLoading: Bool

    var snapshot: [String: Bool] {
        ["canGoBack": canGoBack, "canGoForward": canGoForward,
         "canReload": canReload, "isLoading": isLoading]
    }
}
