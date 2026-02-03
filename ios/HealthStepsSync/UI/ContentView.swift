import SwiftUI

struct ContentView: View {
  @ObservedObject var vm: SyncViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Health Steps Sync")
        .font(.title2)

      Text(vm.status)
        .font(.footnote)

      Button(vm.primaryButtonTitle) {
        vm.primaryButtonTapped()
      }
      .buttonStyle(.borderedProminent)

      if vm.shouldShowResetButton {
        Button("Reset Sync") {
          vm.resetButtonTapped()
        }
        .buttonStyle(.bordered)
      }

      VStack(alignment: .leading, spacing: 6) {
        HStack {
          Text("Upload progress")
            .font(.footnote)
          Spacer()
          Text("\(vm.progressPercent)%")
            .font(.footnote)
        }
        ProgressView(value: Double(vm.progressPercent), total: 100)
      }

      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 4) {
            ForEach(vm.logs.indices, id: \.self) { idx in
              Text(vm.logs[idx])
                .font(.caption2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(idx)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onChange(of: vm.logs.count) { _ in
          guard let last = vm.logs.indices.last else { return }
          proxy.scrollTo(last, anchor: .bottom)
        }
      }
    }
    .padding()
  }
}
