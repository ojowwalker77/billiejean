import Foundation

// Bootstrap avoids the `@main` + `@available` clash: the App type is a plain
// `@available(macOS 14.2, *)` struct and we gate its entry point here.
if #available(macOS 14.2, *) {
    VinylfyStudioApp.main()
} else {
    fatalError("Vinylfy Studio requires macOS 14.2 or later.")
}
