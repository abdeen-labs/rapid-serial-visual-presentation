import SwiftUI

/// The fold of a folding screen where it crosses a view: the iPhone Duo's
/// inner screen. The frame includes the margin the system asks content to
/// keep from the crease. The fold is active while the screen is half open,
/// and inactive while it lies flat, when content may span it.
struct ScreenFold {
    var frame: CGRect
    var isActive: Bool

    /// True for a fold running from the top of the view to the bottom.
    var runsDown: Bool { frame.height > frame.width }

    /// The fold crossing `geo`'s frame, in its coordinates. Nil on screens
    /// without one, and for an inactive fold unless `includeInactive`.
    static func crossing(_ geo: GeometryProxy, includeInactive: Bool = false) -> ScreenFold? {
        // The reserved-region API arrived in the iOS 27.1 SDK.
        #if os(iOS) && canImport(SwiftUI, _version: 8.0.85.29)
        if #available(iOS 27.1, *) {
            let options: ReservedRegion.QueryOptions = includeInactive ? .includeInactive : []
            if let region = geo.reservedRegions(kind: .division, options: options).first(where: { includeInactive || $0.isActive }) {
                return ScreenFold(frame: region.frame, isActive: region.isActive)
            }
        }
        #endif
        return nil
    }
}
