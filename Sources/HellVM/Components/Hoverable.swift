// Hover 响应容器
import SwiftUI

/// Hover 可响应的通用容器
struct Hoverable<Content: View>: View {
    let content: (Bool) -> Content
    @State private var hovering: Bool = false

    init(@ViewBuilder content: @escaping (Bool) -> Content) {
        self.content = content
    }

    var body: some View {
        content(hovering)
            .onHover { hovering = $0 }
    }
}
