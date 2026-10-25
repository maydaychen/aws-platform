import SwiftUI

struct S3BucketListView: View {
    @Environment(\.locale) private var locale
    @ObservedObject var vm: S3ViewModel

    var body: some View {
        let filteredBuckets = vm.filteredBuckets
        VStack(spacing: 0) {
            ListToolbar(
                title: "S3 Buckets",
                isLoading: vm.isBucketsLoading,
                searchText: $vm.bucketSearchText,
                onRefresh: { vm.refresh() },
                onCancel: { vm.cancelBucketLoading() }
            )
            Divider()
            List(filteredBuckets, selection: $vm.selectedBucket) { bucket in
                VStack(alignment: .leading, spacing: 4) {
                    Text(bucket.name)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .help(bucket.name)
                    HStack(spacing: 8) {
                        Text(bucket.region ?? "-")
                        if let creationDate = bucket.creationDate {
                            Text(creationDate.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale)))
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
                if !vm.isBucketsLoading, let error = vm.bucketListError {
                    EmptyStateView(text: error, icon: "exclamationmark.triangle")
                } else if !vm.isBucketsLoading && filteredBuckets.isEmpty {
                    EmptyStateView(text: vm.buckets.isEmpty ? "No S3 buckets" : "No matching buckets", icon: "externaldrive")
                }
            }
            ResourceListFooter(visible: filteredBuckets.count, total: vm.buckets.count)
        }
    }
}
