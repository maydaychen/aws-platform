import SwiftUI

struct S3BucketListView: View {
    @ObservedObject var vm: S3ViewModel

    var body: some View {
        List(vm.buckets, selection: $vm.selectedBucket) { bucket in
            VStack(alignment: .leading, spacing: 4) {
                Text(bucket.name)
                    .fontWeight(.medium)
                HStack(spacing: 8) {
                    Text(bucket.region ?? "-")
                    if let creationDate = bucket.creationDate {
                        Text(creationDate.formatted())
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .onTapGesture {
                vm.selectBucket(bucket)
            }
        }
        .overlay {
            if vm.isLoading {
                ProgressView()
            } else if let error = vm.error {
                EmptyStateView(text: error)
            } else if vm.buckets.isEmpty {
                EmptyStateView(text: "No S3 buckets")
            }
        }
    }
}
