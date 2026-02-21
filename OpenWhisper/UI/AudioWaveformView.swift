import SwiftUI

struct VoiceDots: View {
    let level: Float
    private let dotSize: CGFloat = 8
    private let dotCount = 3
    private let teal = Color(red: 0.08, green: 0.72, blue: 0.65)

    @State private var offsets: [CGFloat] = [0, 0, 0]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<dotCount, id: \.self) { index in
                Circle()
                    .fill(teal)
                    .frame(width: dotSize, height: dotSize)
                    .offset(y: offsets[index])
            }
        }
        .onChange(of: level) { _, newLevel in
            updateDots(newLevel)
        }
        .onAppear {
            updateDots(level)
        }
    }

    private func updateDots(_ inputLevel: Float) {
        let normalized = CGFloat(min(max(inputLevel * 8, 0), 1.0))
        // Center dot bounces most, outer dots slightly less
        let multipliers: [CGFloat] = [0.7, 1.0, 0.7]

        for i in 0..<dotCount {
            let stagger = Double(i) * 0.08
            withAnimation(.spring(response: 0.3, dampingFraction: 0.5).delay(stagger)) {
                offsets[i] = -normalized * 10 * multipliers[i]
            }
        }
    }
}

/// Typing-indicator style: 3 dots bouncing sequentially in a loop
struct BouncingDots: View {
    private let dotSize: CGFloat = 6
    private let dotCount = 3
    private let teal = Color(red: 0.08, green: 0.72, blue: 0.65)

    @State private var activeIndex = 0

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<dotCount, id: \.self) { index in
                Circle()
                    .fill(teal.opacity(index == activeIndex ? 1.0 : 0.4))
                    .frame(width: dotSize, height: dotSize)
                    .offset(y: index == activeIndex ? -6 : 0)
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
