import SwiftUI

/// DISP mode toggle for the portrait system bar — a compact twin of the landscape rail's
/// `displayButton` (which is private to its module). Cycles live → clean → command via the same
/// `NativeAppModel.cycleDisplayMode()`, and shows the same capsule position indicator.
struct PortraitDisplayButton: View {
    @Environment(NativeAppModel.self) private var model

    var body: some View {
        Button {
            model.cycleDisplayMode()
        } label: {
            VStack(spacing: 3) {
                Text("DISP")
                    .font(.system(size: 12, weight: .bold, design: .default))
                HStack(spacing: 3) {
                    ForEach(model.displayOrder) { mode in
                        Capsule()
                            .fill(
                                mode == model.displayMode
                                    ? LiveDesign.info : LiveDesign.hairlineStrong
                            )
                            .frame(width: 14, height: 3)
                    }
                }
            }
            .foregroundStyle(model.displayMode == .live ? LiveDesign.info : LiveDesign.text)
            .frame(
                width: CGFloat(MonitorSideRailControlLayout.displayButtonWidth),
                height: CGFloat(MonitorSideRailControlLayout.displayButtonHeight)
            )
            .liquidGlass(
                in: RoundedRectangle(cornerRadius: LiveDesign.cornerRadius, style: .continuous))
        }
        .buttonStyle(.zcTapTarget)
    }
}
