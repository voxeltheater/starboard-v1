import SwiftUI

struct USBView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                if model.usbRunning {
                    Button("Stop", role: .cancel) { model.stopUSB() }
                        .keyboardShortcut(.cancelAction)
                    ProgressView().controlSize(.small)
                    Text("Watching for boards…").foregroundStyle(.secondary)
                } else {
                    Button("Start Flashing") { model.startUSB() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.firmware == nil || model.busy)
                }
                Spacer()
                if model.usbFlashed > 0 {
                    Text("\(model.usbFlashed) flashed")
                        .font(.title3.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.green)
                }
            }
            Text("Plug boards in one at a time. Each one is checked, flashed, verified and announced with a sound. Boards on pre-1.3 firmware: connect USB **before** powering the board, or power-cycle it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            LogView(lines: model.usbLog,
                    placeholder: "Press Start Flashing, then plug in a \(model.board.name) board.")
        }
        .padding(4)
    }
}
