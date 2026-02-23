import SwiftUI

struct VoiceDots: View {
    let level: Float
    private let dotSize: CGFloat = 5
    private let dotCount = 3
    private let teal = Color(red: 0.08, green: 0.72, blue: 0.65)

    @State private var offsets: [CGFloat] = [0, 0, 0]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<dotCount, id: \.self) { index in
                Circle()
                    .fill(teal)
                    .frame(width: dotSize, height: dotSize)
                    .offset(y: offsets[index])
            }
        }
        .frame(height: 14)
        .onChange(of: level) { _, newLevel in
            updateDots(newLevel)
        }
        .onAppear {
            updateDots(level)
        }
    }

    private func updateDots(_ inputLevel: Float) {
        let normalized = CGFloat(min(max(inputLevel * 8, 0), 1.0))
        let multipliers: [CGFloat] = [0.7, 1.0, 0.7]

        for i in 0..<dotCount {
            let stagger = Double(i) * 0.08
            withAnimation(.spring(response: 0.3, dampingFraction: 0.5).delay(stagger)) {
                offsets[i] = -normalized * 6 * multipliers[i]
            }
        }
    }
}

struct BouncingDots: View {
    private let dotSize: CGFloat = 4
    private let dotCount = 3
    private let teal = Color(red: 0.08, green: 0.72, blue: 0.65)

    @State private var activeIndex = 0

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<dotCount, id: \.self) { index in
                Circle()
                    .fill(teal.opacity(index == activeIndex ? 1.0 : 0.4))
                    .frame(width: dotSize, height: dotSize)
                    .offset(y: index == activeIndex ? -4 : 0)
                    .animation(.spring(response: 0.3, dampingFraction: 0.5), value: activeIndex)
            }
        }
        .onAppear { startLoop() }
    }

    private func startLoop() {
        Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { _ in
            activeIndex = (activeIndex + 1) % dotCount
        }
    }
}
