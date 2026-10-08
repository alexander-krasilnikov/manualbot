import SwiftUI

enum DetailTab: Hashable {
    case source, xray
}

/// The right-hand column. It switches between the source viewer and the X-ray panel; both stay
/// alive, so the open document keeps its place while the presenter looks at the database.
struct DetailColumn: View {
    let source: SourceViewerModel
    let demo: DemoSession
    @Binding var tab: DetailTab
    var previewActions = PreviewActions()

    var body: some View {
        ZStack {
            SourceViewerView(source: source, actions: previewActions)
                .opacity(tab == .source ? 1 : 0)
                .allowsHitTesting(tab == .source)
                .accessibilityHidden(tab != .source)
            XrayPanelView(xray: demo.xray)
                .opacity(tab == .xray ? 1 : 0)
                .allowsHitTesting(tab == .xray)
                .accessibilityHidden(tab != .xray)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Detail", selection: $tab) {
                    Label("Source", systemImage: "doc.text").labelStyle(.iconOnly).tag(DetailTab.source)
                    Label("X-ray", systemImage: "waveform.path.ecg").labelStyle(.iconOnly).tag(DetailTab.xray)
                }
                .pickerStyle(.segmented)
                .frame(width: 120)
                .accessibilityIdentifier("detailTabPicker")
            }
        }
    }
}
