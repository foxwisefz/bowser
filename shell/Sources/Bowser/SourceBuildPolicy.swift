/// Source builds can run without the private admission and hosted-AI service.
/// Enable with `swift build -Xswiftc -DBOWSER_COMMUNITY`.
enum SourceBuildPolicy {
    #if BOWSER_COMMUNITY
    static let community = true
    #else
    static let community = false
    #endif
}
