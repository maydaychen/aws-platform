import SwiftUI

struct ContentView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var profileVM = ProfileViewModel()
    @StateObject private var ec2VM = EC2ViewModel()
    @StateObject private var lambdaVM = LambdaViewModel()
    @StateObject private var s3VM = S3ViewModel()

    @AppStorage("selectedService") private var selectedServiceID = AWSService.ec2.rawValue
    @State private var selectedService: AWSService = .ec2
    @State private var s3BrowsingBucket: String?
    @State private var reconfigureTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            ProfileBarView(vm: profileVM)
            Divider()
            HSplitView {
                ServiceSidebarView(selectedService: $selectedService)
                middlePane
                    .frame(minWidth: 320)
                detailPane
                    .contentTransition(reduceMotion ? .identity : .opacity)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: detailSelectionID)
                    .id([profileVM.selectedProfileID ?? "", profileVM.selectedRegion])
            }
        }
        .onAppear {
            profileVM.loadProfiles()
            selectedService = AWSService(rawValue: selectedServiceID) ?? .ec2
            reconfigureServices()
        }
        .onChange(of: profileVM.selectedProfileID) { _ in
            s3BrowsingBucket = nil
            reconfigureServices()
        }
        .onChange(of: profileVM.selectedRegion) { _ in
            s3BrowsingBucket = nil
            reconfigureServices()
        }
        .onChange(of: selectedService) { _ in
            s3BrowsingBucket = nil
            selectedServiceID = selectedService.rawValue
        }
        .onDisappear {
            reconfigureTask?.cancel()
            Task { await profileVM.shutdown() }
        }
    }

    @ViewBuilder
    private var middlePane: some View {
        switch selectedService {
        case .ec2:
            EC2ListView(vm: ec2VM)
        case .lambda:
            LambdaListView(vm: lambdaVM)
        case .s3:
            if let bucketName = s3BrowsingBucket {
                S3ObjectListView(vm: s3VM, bucketName: bucketName)
            } else {
                S3BucketListView(vm: s3VM)
            }
        }
    }

    private var detailSelectionID: String {
        switch selectedService {
        case .ec2: return "ec2/" + (ec2VM.selectedInstance?.instanceId ?? "")
        case .lambda: return "lambda/" + (lambdaVM.selectedFunction?.functionName ?? "")
        case .s3: return "s3/" + (s3BrowsingBucket ?? s3VM.selectedBucket?.name ?? "") + "/" + (s3VM.selectedObject?.key ?? "")
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        switch selectedService {
        case .ec2:
            if let instance = ec2VM.selectedInstance {
                EC2DetailView(instance: instance, vm: ec2VM)
            } else {
                EmptyStateView(text: "Select an EC2 instance")
            }
        case .lambda:
            if let function = lambdaVM.selectedFunction {
                LambdaDetailView(function: function, vm: lambdaVM)
            } else {
                EmptyStateView(text: "Select a Lambda function")
            }
        case .s3:
            if let bucket = s3VM.selectedBucket, s3BrowsingBucket == nil {
                S3BucketDetailView(bucket: bucket) {
                    s3BrowsingBucket = bucket.name
                    s3VM.navigateToPrefix(bucket: bucket.name, prefix: "")
                }
            } else if let bucketName = s3BrowsingBucket {
                VStack(spacing: 0) {
                    HStack {
                        Button("Back to Buckets") {
                            s3BrowsingBucket = nil
                        }
                        Spacer()
                        Text(bucketName)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    Divider()
                    if let object = s3VM.selectedObject {
                        S3ObjectDetailView(object: object)
                    } else {
                        EmptyStateView(text: "Select an object or folder")
                    }
                }
            } else {
                EmptyStateView(text: "Select an S3 bucket")
            }
        }
    }

    private func reconfigureServices() {
        reconfigureTask?.cancel()
        ec2VM.reset()
        lambdaVM.reset()
        s3VM.reset()

        reconfigureTask = Task {
            do {
                try await Task.sleep(nanoseconds: 75_000_000)
            } catch {
                return
            }
            let isValid = await profileVM.configureProvider()
            guard !Task.isCancelled, isValid else { return }
            ec2VM.configure(provider: profileVM.provider)
            lambdaVM.configure(provider: profileVM.provider)
            s3VM.configure(provider: profileVM.provider)
        }
    }
}
