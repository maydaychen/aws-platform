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
            Divider()
            List(vm.filteredBuckets, selection: $vm.selectedBucket) { bucket in
                VStack(alignment: .leading, spacing: 4) {
                    Text(bucket.name)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .help(bucket.name)
                    HStack(spacing: 8) {
                        Text(bucket.region ?? "-")
                        if let creationDate = bucket.creationDate {
                            Text(creationDate.formatted(date: .abbreviated, time: .omitted))
                        }
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                }
                .padding(.vertical, 4)
                .tag(bucket)
                .contentShape(Rectangle())
                .onTapGesture {
                    vm.selectBucket(bucket)
                }
            }
            .listStyle(.inset)
            .overlay {
                if !vm.isLoading, let error = vm.error {
                    EmptyStateView(text: error, icon: "exclamationmark.triangle")
                } else if !vm.isLoading && vm.filteredBuckets.isEmpty {
                    EmptyStateView(text: vm.buckets.isEmpty ? "No S3 buckets" : "No matching buckets", icon: "externaldrive")
                }
            }
            ResourceListFooter(visible: vm.filteredBuckets.count, total: vm.buckets.count)
        }
    }
}
