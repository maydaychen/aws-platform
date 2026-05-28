import SwiftUI

enum AWSService: String, CaseIterable, Identifiable {
    case ec2 = "EC2"
    case lambda = "Lambda"
    case s3 = "S3"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .ec2:
            return "server.rack"
        case .lambda:
            return "function"
        case .s3:
            return "externaldrive"
        }
    }
}

struct ServiceSidebarView: View {
    @Binding var selectedService: AWSService

    var body: some View {
        VStack(spacing: 8) {
            ForEach(AWSService.allCases) { service in
                Button {
                    selectedService = service
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: service.icon)
                            .font(.title3)
                        Text(service.rawValue)
                            .font(.caption2)
                    }
                    .frame(width: 72, height: 60)
                    .background(selectedService == service ? Color.accentColor.opacity(0.18) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(12)
    }
}
