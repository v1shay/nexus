import CoreGraphics

struct NotchGeometry {
    static let wingWidth: CGFloat = 62
    /// Compact states stay within the menu-bar/notch height. Only a live
    /// second text line may use this shallow, controlled reveal.
    static let compactTextReveal: CGFloat = 12

    static func compactHeight(for physicalNotchSize: CGSize) -> CGFloat {
        physicalNotchSize.height
    }

    static func compactTextHeight(for physicalNotchSize: CGSize) -> CGFloat {
        compactHeight(for: physicalNotchSize) + compactTextReveal
    }

    static func listeningSize(for physicalNotchSize: CGSize) -> CGSize {
        CGSize(
            width: physicalNotchSize.width + wingWidth * 2,
            height: compactHeight(for: physicalNotchSize)
        )
    }

    static func horizontalRegions(in listeningSize: CGSize) -> (leftWing: CGRect, notchGap: CGRect, rightWing: CGRect) {
        let notchWidth = max(0, listeningSize.width - wingWidth * 2)
        let left = CGRect(x: 0, y: 0, width: wingWidth, height: listeningSize.height)
        let notch = CGRect(x: left.maxX, y: 0, width: notchWidth, height: listeningSize.height)
        let right = CGRect(x: notch.maxX, y: 0, width: wingWidth, height: listeningSize.height)
        return (left, notch, right)
    }

    static func centeredTopFrame(for size: CGSize, on screenFrame: CGRect) -> CGRect {
        CGRect(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }
}
