import SwiftUI

/// Winkelnet's brand colors, as on winkelnet.com
enum Theme {
    static let violet = Color(red: 124 / 255, green: 58 / 255, blue: 237 / 255)
    static let blue = Color(red: 47 / 255, green: 87 / 255, blue: 239 / 255)
    static let cyan = Color(red: 6 / 255, green: 182 / 255, blue: 212 / 255)
    static let ink = Color(red: 10 / 255, green: 10 / 255, blue: 15 / 255)

    static let gradient = LinearGradient(colors: [violet, blue, cyan],
                                         startPoint: .topLeading, endPoint: .bottomTrailing)
}
