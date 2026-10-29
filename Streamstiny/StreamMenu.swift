import SwiftUI

struct StreamMenu: View {
  let library: StreamLibrary
  let controls: PlaybackControls
  let addStream: () -> Void
  @AppStorage("enableStreamPinning") private var enablePinning = true

  var body: some View {
    @Bindable var controls = controls
    Button { controls.menuPresented = true } label: {
      Image(systemName: "line.3.horizontal").frame(width: 44, height: 44)
    }
    .accessibilityLabel("Choose stream")
    .popover(isPresented: $controls.menuPresented, arrowEdge: .top) {
      NavigationStack {
        List {
          Section("Now Playing") {
            row(library.selected, name: library.name(for: library.selected))
          }
          let pinned = enablePinning ? library.pinned.filter { $0.id != library.selected.id } : []
          if !pinned.isEmpty {
            Section("Pinned") {
              ForEach(pinned) { item in row(item.source, name: library.name(for: item.source)) }
            }
          }
          let pinnedIDs = enablePinning ? Set(library.pinned.map(\.id)) : []
          let live = library.directory.filter { $0.id != library.selected.id && !pinnedIDs.contains($0.id) }
          if !live.isEmpty {
            Section("Live streams") {
              ForEach(live) { item in row(item.source, name: item.name) }
            }
          }
          Button {
            controls.menuPresented = false
            addStream()
          } label: { Label("Add stream", systemImage: "plus") }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Streams").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { controls.menuPresented = false } } }
      }
      .frame(idealWidth: 360, idealHeight: 480)
      .presentationCompactAdaptation(.popover)
      .tint(.blue)
      .foregroundStyle(Color.primary)
    }
  }

  private func row(_ source: StreamSource, name: String) -> some View {
    HStack {
      Button {
        library.select(source)
        controls.menuPresented = false
      } label: {
        HStack {
          VStack(alignment: .leading) {
            Text(name).foregroundStyle(.primary).multilineTextAlignment(.leading)
            Text(source.provider.rawValue).font(.caption).foregroundStyle(.secondary)
          }
          Spacer()
          Image(systemName: source.id == library.selected.id ? "play.fill" : "play.rectangle")
        }.contentShape(Rectangle())
      }.accessibilityLabel("Play " + name)
      if enablePinning {
        let pinned = library.pinned.contains { $0.id == source.id }
        Button { library.togglePin(source) } label: {
          Image(systemName: pinned ? "pin.fill" : "pin").frame(width: 44, height: 44)
        }
        .accessibilityLabel((pinned ? "Unpin " : "Pin ") + name)
        .accessibilityIdentifier("pin-" + source.id)
      }
    }.buttonStyle(.borderless)
  }
}
