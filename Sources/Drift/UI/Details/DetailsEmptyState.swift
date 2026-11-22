// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

struct DetailsEmptyState: View {
    let title: String
    let systemImage: String

    var body: some View {
        VStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text(title)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 190)
    }
}
