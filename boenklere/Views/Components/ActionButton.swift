import SwiftUI

struct BoenklereActionButtonLabel: View {
    let title: String
    var systemImage: String? = nil
    var height: CGFloat = 52
    var horizontalPadding: CGFloat = 18
    var isFullWidth: Bool = true
    var textColor: Color = Color(red: 0.07, green: 0.34, blue: 0.68)
    var fillColor: Color = Color(red: 0.82, green: 0.92, blue: 1.0)

    var body: some View {
        HStack(spacing: 12) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.headline)
            }
            Text(title)
                .font(.headline)
                .fontWeight(.bold)
            if isFullWidth {
                Spacer()
            }
        }
        .foregroundColor(textColor)
        .frame(maxWidth: isFullWidth ? .infinity : nil, alignment: .leading)
        .frame(height: height)
        .padding(.horizontal, horizontalPadding)
        .background(fillColor, in: Capsule())
    }
}
