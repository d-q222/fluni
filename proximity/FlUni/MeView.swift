import SwiftUI

/// Set my own status, honestly worded, plus the way into the Developer screen.
struct MeView: View {
    @ObservedObject var model: ProximityModel
    @State private var confirmPositive = false
    @State private var showDeveloper = false

    private struct Option {
        let risk: Risk
        let title: String
        let detail: String
        let icon: String
        let tint: Color
    }

    private let options = [
        Option(risk: .none, title: "I feel fine", detail: "Phones near you see: healthy.", icon: "face.smiling", tint: Theme.sage),
        Option(risk: .possible, title: "I have symptoms", detail: "Phones near you see: possibly sick. Their exposure time counts half.", icon: "thermometer.medium", tint: Theme.sun),
        Option(risk: .contagious, title: "I tested positive", detail: "Phones near you see: contagious, and may alert their owners.", icon: "cross.case", tint: Theme.fire),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("How are you doing?").font(.fluni(.title3, weight: .bold)).foregroundStyle(Theme.ink)
                    ForEach(options, id: \.risk) { row($0) }
                    since
                    Text("Only your status and a random ID that changes every 15 minutes are shared with phones nearby. No name, no location.")
                        .font(.fluni(.footnote)).foregroundStyle(Theme.ink2)
                        .padding(.top, 4)
                    NavigationLink { SettingsView(model: model) } label: {
                        Label("Settings", systemImage: "gearshape").font(.fluni(.body, weight: .semibold)).foregroundStyle(Theme.ink).frame(minHeight: 44)
                    }
                    Button { showDeveloper = true } label: {
                        Text("Developer tools").font(.fluni(.footnote)).foregroundStyle(Theme.ink3).frame(minHeight: 44)
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(16)
            }
            .background(Theme.paper)
            .navigationTitle("Me")
            .sheet(isPresented: $showDeveloper) { DeveloperView(model: model) }
            .confirmationDialog("Share that you tested positive?", isPresented: $confirmPositive, titleVisibility: .visible) {
                Button("Yes, I tested positive", role: .destructive) { model.setMyStatus(.contagious) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Fluni phones near you will see a contagious status (nothing else about you) and may warn their owners. You can change it any time.")
            }
        }
    }

    private func row(_ o: Option) -> some View {
        let selected = model.myRisk == o.risk
        return Button {
            if o.risk == .contagious && model.myRisk != .contagious { confirmPositive = true } else { model.setMyStatus(o.risk) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: o.icon).font(.title3).frame(width: 36, height: 36)
                    .background(o.tint.opacity(0.45), in: Circle()).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(o.title).font(.fluni(.body, weight: .semibold))
                    Text(o.detail).font(.fluni(.footnote)).foregroundStyle(Theme.ink2).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Theme.ink : Theme.ink3).accessibilityHidden(true)
            }
            .foregroundStyle(Theme.ink)
            .card(fill: selected ? Theme.surface2 : Theme.surface)
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(selected ? Theme.ink : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }

    @ViewBuilder private var since: some View {
        if let at = model.statusSetAt {
            Text("Status set \(at.formatted(date: .abbreviated, time: .shortened))")
                .font(.fluni(.footnote)).foregroundStyle(Theme.ink2)
        } else {
            Text("You haven't set a status yet; phones near you see \"healthy\".")
                .font(.fluni(.footnote)).foregroundStyle(Theme.ink2)
        }
    }
}
