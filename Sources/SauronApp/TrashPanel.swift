import SwiftUI
import DiskCore

struct TrashPanel: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmEmpty = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Marked for Trash")
                .font(.headline)
                .padding(12)

            if model.markedItems.isEmpty {
                VStack {
                    Spacer()
                    Text("Click items in the map\nto mark them for the trash.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .font(.callout)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List {
                    ForEach(model.markedItems, id: \.path) { item in
                        HStack {
                            Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.name).lineLimit(1)
                                Text(item.path)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            Text(Format.bytes(item.size))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Button {
                                model.unmark(item)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
                .listStyle(.inset)
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Will free:")
                    Spacer()
                    Text(Format.bytes(model.markedTotal))
                        .fontWeight(.bold)
                }
                .font(.system(size: 12))

                Button {
                    model.moveMarkedToTrash()
                } label: {
                    Label(
                        model.markedItems.count == 1
                            ? "Move 1 Item to Trash"
                            : "Move \(model.markedItems.count) Items to Trash",
                        systemImage: "trash"
                    )
                    .frame(maxWidth: .infinity)
                }
                .disabled(model.markedItems.isEmpty || model.isTrashing)

                Divider()

                HStack {
                    Text("Free space:")
                    Spacer()
                    Text(Format.bytes(model.displayedFreeSpace))
                        .fontWeight(.bold)
                        .foregroundStyle(model.optimisticFreeSpace != nil ? Color.green : Color.primary)
                }
                .font(.system(size: 12))
                .help(model.optimisticFreeSpace != nil
                      ? "Optimistic estimate — the system hasn't reported the reclaimed space yet"
                      : "Available space on the home volume")

                Button(role: .destructive) {
                    confirmEmpty = true
                } label: {
                    Label("Empty Trash…", systemImage: "trash.slash")
                        .frame(maxWidth: .infinity)
                }
                .confirmationDialog(
                    "Empty the Trash?",
                    isPresented: $confirmEmpty
                ) {
                    Button("Empty Trash", role: .destructive) { model.emptyTrash() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("All items in the Trash will be permanently deleted. This cannot be undone.")
                }

                if let error = model.lastError {
                    ScrollView {
                        Text(error)
                            .font(.system(size: 10))
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 60)
                }
            }
            .padding(12)
        }
        .frame(minWidth: 260, maxWidth: 320)
    }
}
