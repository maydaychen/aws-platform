import SwiftUI

struct S3BucketListView: View {
    @ObservedObject var vm: S3ViewModel

    var body: some View {
        VStack(spacing: 0) {
            ListToolbar(
                title: "S3 Buckets",
                isLoading: vm.isLoading,
                searchText: $vm.bucketSearchText,
                onRefresh: { vm.refresh() },
                onCancel: { vm.cancelLoading() }
            )
            List(vm.filteredBuckets, selection: $vm.selectedBucket) { bucket in
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
                } else if vm.filteredBuckets.isEmpty {
                    EmptyStateView(text: "No S3 buckets")
                }
            }
        }
    }
}
