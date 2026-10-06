import SwiftUI

/// The live log of what the app and Couchbase Lite do behind each action.
struct XrayPanelView: View {
    let xray: XrayModel

    var body: some View {
        VStack(spacing: 0) {
            XrayControls(xray: xray)
            Divider()
            XrayStatusBar(xray: xray)
            Divider()
            let groups = xray.visibleGroups
            if groups.isEmpty {
                ContentUnavailableView(
                    "Nothing yet", systemImage: "waveform.path.ecg",
                    description: Text("Import a document or ask a question to see what happens inside the database."))
                    .accessibilityIdentifier("xrayEmpty")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(groups) { XrayGroupView(group: $0, xray: xray) }
                    }
                    .padding()
                }
            }
        }
        .dynamicTypeSize(xray.textSize)
        .task { xray.network.start() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("xrayPanel")
    }
}

/// A switch shown as an icon. The title still names it for VoiceOver and the pointer tooltip.
private struct IconToggle: View {
    let title: String
    let systemImage: String
    @Binding var isOn: Bool

    init(_ title: String, systemImage: String, isOn: Binding<Bool>) {
        self.title = title
        self.systemImage = systemImage
        _isOn = isOn
    }

    var body: some View {
        Toggle(isOn: $isOn) { Label(title, systemImage: systemImage) }
            .toggleStyle(.button)
            .labelStyle(.iconOnly)
            .help(title)
    }
}

private struct XrayStatusBar: View {
    let xray: XrayModel

    var body: some View {
        HStack(spacing: 14) {
            Label(xray.network.isOnline ? "Network: online" : "Network: offline", systemImage: xray.network.isOnline ? "wifi" : "wifi.slash")
                .foregroundStyle(xray.network.isOnline ? Color.secondary : Color.orange)
                .accessibilityIdentifier("xrayNetworkStatus")
            if xray.usesStubModels {
                Label("Stub models: distances are not real", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("xrayStubBadge")
            }
            Spacer()
            if xray.pendingCount > 0 {
                Text("\(xray.pendingCount) waiting").foregroundStyle(.secondary).accessibilityIdentifier("xrayPending")
            }
        }
        .font(.caption)
        .padding(.horizontal)
        .padding(.vertical, 6)
    }
}

private struct XrayControls: View {
    @Bindable var xray: XrayModel
    @State private var confirmingReset = false

    var body: some View {
        HStack(spacing: 12) {
            IconToggle("Why it matters", systemImage: "lightbulb", isOn: $xray.captions)
                .accessibilityIdentifier("xrayCaptionsToggle")
            IconToggle("Background activity", systemImage: "clock.arrow.circlepath", isOn: $xray.showBackground)
                .accessibilityIdentifier("xrayBackgroundToggle")
            IconToggle("Slow reveal", systemImage: "tortoise", isOn: $xray.slowReveal)
                .accessibilityIdentifier("xraySlowToggle")
            Spacer()
            ControlGroup {
                Button("Smaller text", systemImage: "textformat.size.smaller") { xray.shrinkText() }
                    .disabled(!xray.canShrinkText)
                    .accessibilityIdentifier("xrayTextSmaller")
                Button("Larger text", systemImage: "textformat.size.larger") { xray.growText() }
                    .disabled(!xray.canGrowText)
                    .accessibilityIdentifier("xrayTextLarger")
            }
            .labelStyle(.iconOnly)
            .fixedSize()
            Button("Clear", systemImage: "xmark.circle") { xray.clear() }
                .accessibilityIdentifier("xrayClearButton")
            Button("Reset demo", systemImage: "arrow.counterclockwise", role: .destructive) { confirmingReset = true }
                .disabled(xray.resetAction == nil || xray.isResetting)
                .accessibilityIdentifier("xrayResetButton")
        }
        .confirmationDialog(
            "Reset the demo?", isPresented: $confirmingReset, titleVisibility: .visible
        ) {
            Button("Delete everything and import the samples", role: .destructive) {
                Task { await xray.resetDemo() }
            }
            .accessibilityIdentifier("xrayResetConfirm")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes every document and chat in this app, then imports four sample documents.")
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }
}

private struct XrayGroupView: View {
    let group: TraceGroup
    let xray: XrayModel

    var body: some View {
        DisclosureGroup(
            isExpanded: Binding(get: { xray.isExpanded(group) }, set: { xray.setExpanded(group, $0) })
        ) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(group.events) { event in
                    Divider()
                    XrayEventRow(event: event, group: group, xray: xray)
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(group.title).font(.headline).lineLimit(2)
                Text("\(XrayFormat.time(group.startedAt)) · \(XrayFormat.duration(group.duration)) · \(group.events.count) events")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            // On the label only: an identifier on the whole group would also replace those of the events inside.
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("xrayGroup-\(group.title)")
        }
    }
}
